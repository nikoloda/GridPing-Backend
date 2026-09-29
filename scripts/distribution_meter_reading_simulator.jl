using PowerModelsDistribution
using Ipopt
using JuMP
using Statistics
using Random
using Dates

cd(@__DIR__)

# Silence PowerModels/Memento warnings and keep Ipopt output quiet
# silence()

# Import DB operations
include("../src/DB_AWS_PostgreSQL.jl")
include("../src/DB_SQLite.jl")

# Which DBs to populate
const USE_AWS_POSTGRES = true
const USE_LOCAL_SQLITE = false

db_path = "../test_simple_grid_database.sqlite"


ideal_case_path = "../cases/distribution/8500-Node/Master-unbal.dss"

# GRID EDGE: Phase A residential meter at SX_293471A (Primary node 293471).
# Service drop: Line.Tpx293471A0  bus1=X_293471A.1.2  Bus2=SX_293471A.1.2  linecode=4/0Triplex  length=50 ft
# Meter at SX_ (house), not X_ (pole transformer), so PQ includes the triplex drop.
meter_bus_dss = "SX_293471A"   # OpenDSS bus for power-flow lookup
meter_bus_key = lowercase(meter_bus_dss)
meter_bus_db_id = 293471       # INTEGER records.bus_id / Lambda bus_id

function bus_voltage_pu(bus)
    haskey(bus, "vm") && return bus["vm"]
    return bus["w"][1]
end

function scale_network_loads!(network, load_mult)
    for (_, load) in network["load"]
        load["pd_nom"] *= load_mult
        load["qd_nom"] *= load_mult
    end
end

# Ideal = min diurnal load (transmission still uses fixed case2383; dist PQ is vs lightest day).
function solve_ideal_baseline(network, silent_solver, load_mult)
    println("[db_population_poller] solving ideal at loadmult=$load_mult")

    sys = deepcopy(network)
    scale_network_loads!(sys, load_mult)
    ideal_result = solve_mc_pf(sys, LinDist3FlowPowerModel, silent_solver)
    ideal_status = haskey(ideal_result, "termination_status") ? string(ideal_result["termination_status"]) : "UNKNOWN"
    if !occursin("LOCALLY_SOLVED", ideal_status) || !haskey(ideal_result, "solution")
        error("Ideal case did not solve cleanly: $ideal_status")
    end

    ideal_buses = ideal_result["solution"]["bus"]
    ideal_nominal_voltage = mean(bus_voltage_pu(bus) for bus in values(ideal_buses))

    ideal_meter_vm = bus_voltage_pu(ideal_buses[meter_bus_key])
    return ideal_nominal_voltage, ideal_meter_vm
end

# Diurnal curve for 24 hr case files (No outages, islands, non-converged etc.)
# Taken from loadshape.dss in OpenDSS

diurnal_curve = [
    0.677, 0.6256, 0.6087, 0.5833, 0.58028, 0.6025, 0.657, 0.7477, 0.832, 0.88, 0.94, 0.989,
    0.985, 0.98, 0.9898, 0.999, 1, 0.958, 0.936, 0.913, 0.876, 0.876, 0.828, 0.756,
]

const diurnal_min_mult = minimum(diurnal_curve)

# Extra loadmult factors on diurnal (rand() < interrupt_prob). Third flag: scale only SX_293471A loads.
# Outage rows only when PF does not converge (status=0, pq=-100), same as transmission.
const LOAD_MULT_EVENTS = [
    # Grid wide events
    ("city_spike", 1.6, false),
    ("heat_wave", 1.25, false),
    ("ev_block", 1.15, false),
    ("solar_export", 0.85, false),
    ("industrial_ramp", 1.35, false),
    ("weekend_lull", 0.92, false),
    ("grid_stress", 2.15, false),
    ("grid_stress", 2.4, false),
    ("grid_stress", 2.9, false),
    ("grid_stress", 3, false),
    ("No load", 0.0, false),

    # Meter only events
    ("home_ev", 2.8, true),
    ("heat_pump", 1.75, true),
    ("ac_surge", 3.2, true),
    ("battery_export", 0.45, true)
]

# Load the base case once; scale pd_nom/qd_nom per hour in the loop
network = parse_file(ideal_case_path)
silent_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)

ideal_nominal_voltage, ideal_meter_vm = solve_ideal_baseline(network, silent_solver, diurnal_min_mult)

# Determine starting hourly index (start at hour 1)
let hourly_index = 1

# Number of hourly steps; default to 24
N_hourly = 24

# Parameter to set how often the meter collects data in seconds
reading_interval = 45

# Probability at each interval to process a random event case (0.0..1.0)
interrupt_prob = 0.10


# PRINT PARAMS:
println("[db_population_poller] dss=$meter_bus_dss db_bus_id=$meter_bus_db_id steps=$N_hourly interval=$(reading_interval)s interrupt=$interrupt_prob postgres=$USE_AWS_POSTGRES sqlite=$USE_LOCAL_SQLITE")


# MAIN METER READING LOOP (runs once every reading_interval):

while true
    # Terminate once we loop through all the hourly cases
    if hourly_index > N_hourly
        break
    end

    # FILE SELECTION: optional event interrupt, else scheduled diurnal hour.
    diurnal_mult = diurnal_curve[hourly_index]
    event_name = "diurnal"
    event_factor = 1.0
    event_meter_only = false
    is_event = false

    if rand() < interrupt_prob
        event_name, event_factor, event_meter_only = LOAD_MULT_EVENTS[rand(1:length(LOAD_MULT_EVENTS))]
        is_event = true
    end
    load_mult = diurnal_mult * (event_meter_only ? 1.0 : event_factor)

    # Timestamp reading
    time_stamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")


    # FILE PROCESSING:


    # Create a fresh network state for this hour and scale loads (real-time case gen)
    sys = deepcopy(network)
    scale_network_loads!(sys, load_mult)
    if is_event && event_meter_only
        for (_, load) in sys["load"]
            if lowercase(string(get(load, "bus", ""))) == meter_bus_key
                load["pd_nom"] *= event_factor
                load["qd_nom"] *= event_factor
            end
        end
    end
    result = solve_mc_pf(sys, LinDist3FlowPowerModel, silent_solver)

    # Converged only on a feasible local solve (excludes LOCALLY_INFEASIBLE).
    has_solution = haskey(result, "solution") && haskey(result["solution"], "bus") && !isempty(result["solution"]["bus"])
    status_str = string(get(result, "termination_status", ""))
    is_converged = Int(has_solution && occursin("LOCALLY_SOLVED", status_str))

    # We should see if the grid converges and decide whether to analyze based on that
    if is_converged == 1
        # Converged
        solved_bus = result["solution"]["bus"]

        # Calculate global power quality
        mean_global_voltage = mean(bus_voltage_pu(bus) for bus in values(solved_bus))
        global_pq_avg = mean_global_voltage - ideal_nominal_voltage

        # Local PQ: same contract as transmission (meter V − ideal V at meter, p.u.)
        local_pq = bus_voltage_pu(solved_bus[meter_bus_key]) - ideal_meter_vm

        # Get the number of islands in the whole grid
        num_islands = length(calc_connected_components(sys))

    else
        # Not converged
        global_pq_avg = -100.0
        local_pq = -100.0
        num_islands = 0
    end


    # WRITE RESULTS TO DB:
    println("\n", "-" ^ 80)

    if USE_LOCAL_SQLITE
        println("[db_population_poller] writing sqlite")
        conn_sq = connect_sqlite()
        ensure_sqlite_schema(conn_sq)
        insert_global_record_sqlite(conn_sq, time_stamp, global_pq_avg, num_islands, is_converged)
        insert_record_sqlite(conn_sq, time_stamp, local_pq, is_converged, meter_bus_db_id)
        # peek_sqlite(conn_sq)
    end

    if USE_AWS_POSTGRES
        println("[db_population_poller] writing postgres")
        conn_pg = connect_pg()
        # Ensure schema exists in Postgres (mirror SQLite init)
        ensure_postgres_schema(conn_pg)
        insert_global_record_pg(conn_pg, time_stamp, global_pq_avg, num_islands, is_converged)
        insert_record_pg(conn_pg, time_stamp, local_pq, is_converged, meter_bus_db_id)
        # peek_pg(conn_pg)
        close_pg(conn_pg)
    end

    kind = is_event ? "event" : "diurnal"
    meter_tag = event_meter_only ? "@meter" : ""
    println("[db_population_poller] [$time_stamp] hour=$hourly_index $kind=$event_name$meter_tag×$event_factor diurnal=$diurnal_mult loadmult=$load_mult | converged=$(is_converged == 1) | islands=$num_islands | outage=$(is_converged == 0) | pq($meter_bus_db_id)=$local_pq | g_pq=$global_pq_avg | $status_str")

    # Advance only after the scheduled diurnal hour. Events replay the same hour index to ensure all 24 diurnal hours are simulated.
    if !is_event
        hourly_index += 1
    end
    
    sleep(reading_interval)
end

println("[db_population_poller] finished $N_hourly hourly steps.")
end
