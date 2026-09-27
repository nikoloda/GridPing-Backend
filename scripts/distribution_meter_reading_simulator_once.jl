# Single-run debug driver: one OpenDSS case (ideal = current), no hourly loop / sleep.
using PowerModelsDistribution
using Ipopt
using JuMP
using Statistics
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

case_path = "../cases/distribution/8500-Node/Master-unbal.dss"

# GRID EDGE: Phase A residential meter at SX_293471A (Primary node 293471).
# Service drop: Line.Tpx293471A0  bus1=X_293471A.1.2  Bus2=SX_293471A.1.2  linecode=4/0Triplex  length=50 ft
# Meter at SX_ (house), not X_ (pole transformer), so PQ includes the triplex drop.
meter_bus_dss = "SX_293471A"   # OpenDSS bus for power-flow lookup
meter_bus_key = lowercase(meter_bus_dss)  # PMD solution dict uses lowercase ids
meter_bus_db_id = 293471       # INTEGER records.bus_id / Lambda bus_id

# LinDist3Flow bus results use "w" (per-terminal p.u. voltage), not transmission-style "vm".
function bus_voltage_pu(bus)
    haskey(bus, "vm") && return bus["vm"]
    return bus["w"][1]
end

# Solve the ideal case once to have a baseline for comparison
function solve_distribution_case(case_path)
    println("[distribution_once] parsing and solving: $case_path")

    sys = parse_file(case_path)
    silent_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)
    result = solve_mc_pf(sys, LinDist3FlowPowerModel, silent_solver)
    status_str = haskey(result, "termination_status") ? string(result["termination_status"]) : "UNKNOWN"
    has_solution = haskey(result, "solution") && haskey(result["solution"], "bus") && !isempty(result["solution"]["bus"])
    is_converged = Int(has_solution && occursin("LOCALLY_SOLVED", status_str))

    if is_converged != 1
        error("Case did not solve cleanly: $status_str")
    end

    solved_bus = result["solution"]["bus"]
    ideal_nominal_voltage = mean(bus_voltage_pu(bus) for bus in values(solved_bus))
    ideal_meter_vm = bus_voltage_pu(solved_bus[meter_bus_key])

    return (sys = sys, result = result, status_str = status_str, is_converged = is_converged,
            solved_bus = solved_bus, ideal_nominal_voltage = ideal_nominal_voltage,
            ideal_meter_vm = ideal_meter_vm)
end

# PRINT PARAMS:
println("[distribution_once] dss=$meter_bus_dss db_bus_id=$meter_bus_db_id case=$case_path postgres=$USE_AWS_POSTGRES sqlite=$USE_LOCAL_SQLITE")
println("[distribution_once] case exists on disk: $(isfile(case_path))")
println("[distribution_once] ideal case and current case are the same file (single solve)")

# Solve the ideal case once to have a baseline for comparison
run = solve_distribution_case(case_path)
sys = run.sys
solved_bus = run.solved_bus
ideal_nominal_voltage = run.ideal_nominal_voltage
ideal_meter_vm = run.ideal_meter_vm
status_str = run.status_str
is_converged = run.is_converged

println("[distribution_once] termination_status=$status_str is_converged=$is_converged")
println("[distribution_once] baseline ideal_nominal_voltage=$ideal_nominal_voltage ideal_meter_vm=$ideal_meter_vm (bus=$meter_bus_dss)")
println("[distribution_once] solution bus count=$(length(solved_bus))")

# Timestamp reading
time_stamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
println("[distribution_once] record_time=$time_stamp")


# FILE PROCESSING:
# Current case is identical to the ideal baseline (same DSS, same solution).

# We should see if the grid converges and decide whether to analyze based on that
if is_converged == 1
    # Converged
    # Get solved bus voltages
    # Calculate global power quality
    mean_global_voltage = mean(bus_voltage_pu(bus) for bus in values(solved_bus))
    global_pq_avg = mean_global_voltage - ideal_nominal_voltage
    println("[distribution_once] mean_global_voltage=$mean_global_voltage global_pq_avg=$global_pq_avg")

    # Calculate power quality at the distribution meter (OpenDSS bus, stored as meter_bus_db_id in DB)
    meter_vm = bus_voltage_pu(solved_bus[meter_bus_key])
    local_pq = meter_vm - ideal_meter_vm
    println("[distribution_once] meter_vm=$meter_vm local_pq=$local_pq (expect ~0 when ideal = current)")

    # Get the number of islands in the whole grid
    num_islands = length(calc_connected_components(sys))
    println("[distribution_once] num_islands=$num_islands")

else
    # Not converged
    global_pq_avg = -100.0
    local_pq = -100.0
    num_islands = 0
    println("[distribution_once] non-converged — using sentinel PQ values")
end


# WRITE RESULTS TO DB:
println("\n", "-" ^ 80)

if USE_LOCAL_SQLITE
    println("[distribution_once] writing sqlite")
    conn_sq = connect_sqlite()
    ensure_sqlite_schema(conn_sq)
    insert_global_record_sqlite(conn_sq, time_stamp, global_pq_avg, num_islands, is_converged)
    insert_record_sqlite(conn_sq, time_stamp, local_pq, is_converged, meter_bus_db_id)
    # peek_sqlite(conn_sq)
end

if USE_AWS_POSTGRES
    println("[distribution_once] writing postgres")
    conn_pg = connect_pg()
    # Ensure schema exists in Postgres (mirror SQLite init)
    ensure_postgres_schema(conn_pg)
    insert_global_record_pg(conn_pg, time_stamp, global_pq_avg, num_islands, is_converged)
    insert_record_pg(conn_pg, time_stamp, local_pq, is_converged, 6)
    # peek_pg(conn_pg)
    close_pg(conn_pg)
    println("[distribution_once] postgres write complete")
end

println("[distribution_once] [$time_stamp] $(basename(case_path)) | converged=$(is_converged == 1) | islands=$num_islands | outage=$(is_converged == 0) | pq($meter_bus_db_id)=$local_pq | g_pq=$global_pq_avg | $status_str")
println("[distribution_once] done.")
