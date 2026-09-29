# The main file which drives the simulation flow for transmission grid cases 
# It acts like how a next generation smart meter would receive data and upload to the AWS DB


using PowerModels
using Ipopt
using JuMP
using Statistics
using Random
using Dates

cd(@__DIR__)

# Silence PowerModels/Memento warnings and keep Ipopt output quiet
PowerModels.silence()

# Import DB operations
include("../src/DB_AWS_PostgreSQL.jl")
include("../src/DB_SQLite.jl")

# Which DBs to populate
const USE_AWS_POSTGRES = true
const USE_LOCAL_SQLITE = false

db_path = "../test_simple_grid_database.sqlite"


ideal_case_path = "../cases/transmission/case2383wp.m"


# Solve the ideal case once to have a baseline for comparison
function solve_ideal_baseline(case_path)
    println("[db_population_poller] solving ideal case for reference voltages")

    ideal_sys = PowerModels.parse_file(case_path)
    silent_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)
    ideal_result = solve_ac_pf(ideal_sys, silent_solver)
    ideal_status = haskey(ideal_result, "termination_status") ? string(ideal_result["termination_status"]) : "UNKNOWN"
    if ideal_status != "LOCALLY_SOLVED" || !haskey(ideal_result, "solution")
        error("Ideal case did not solve cleanly: $ideal_status")
    end

    ideal_buses = ideal_result["solution"]["bus"]
    ideal_bus_status = [ideal_buses[string(i)]["vm"] for i in 1:length(ideal_buses)]
    ideal_nominal_voltage = mean(bus["vm"] for bus in values(ideal_result["solution"]["bus"]))

    return ideal_bus_status, ideal_nominal_voltage
end

# Solve the ideal case once to have a baseline for comparison
ideal_bus_status, ideal_nominal_voltage = solve_ideal_baseline(ideal_case_path)


# "Standard" 24 hr case files (No outages, islands, non-converged etc.)
case_dir = "../cases/transmission/generated_cases"

# Event cases directory
event_dir = "../cases/transmission/event_cases"

# Parameter to set the meter being simulate
meter_bus_id = 6

# Determine starting hourly index (start at hour 1)
let hourly_index = 1

# Number of hourly steps; default to 24
N_hourly = 24

# Parameter to set how often the meter collects data
reading_interval = 45

# Probability at each interval to process a random event case (0.0..1.0)
interrupt_prob = 0.35


# PRINT PARAMS:
println("[db_population_poller] bus=$meter_bus_id steps=$N_hourly interval=$(reading_interval)s interrupt=$interrupt_prob postgres=$USE_AWS_POSTGRES sqlite=$USE_LOCAL_SQLITE")


# MAIN METER READING LOOP (runs once every reading_interval):

while true
    # Terminate once we loop through all the hourly cases
    if hourly_index > N_hourly
        break
    end

    # FILE SELECTION:
    # Decide whether to interrupt with a random event case
    next_file = nothing
    if rand() < interrupt_prob
        # pick any event case (repeats allowed)
        event_candidates = isdir(event_dir) ? filter(f -> endswith(lowercase(f), ".m"), readdir(event_dir, join = true)) : String[]
        if !isempty(event_candidates)
            next_file = event_candidates[rand(1:length(event_candidates))]
        end
    end

    # If not interrupted or no event available, construct the hourly filename from counter
    if next_file === nothing
        # e.g. hourly_case_1.m .. hourly_case_24.m
        candidate_path = joinpath(case_dir, "hourly_case_$(hourly_index).m")
        next_file = candidate_path
    end

    # Timestamp reading
    time_stamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")


    # FILE PROCESSING:

    # Solve file
    sys = PowerModels.parse_file(next_file)
    silent_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)
    result = solve_ac_pf(sys, silent_solver)

    # Converged only on a feasible local solve (excludes LOCALLY_INFEASIBLE).
    has_solution = haskey(result, "solution") && haskey(result["solution"], "bus") && !isempty(result["solution"]["bus"])
    status_str = string(get(result, "termination_status", ""))
    is_converged = Int(has_solution && occursin("LOCALLY_SOLVED", status_str))

    # We should see if the grid converges and decide whether to analyze based on that
    if is_converged == 1
        # Converged
        # Get solved bus voltages
        solved_bus = result["solution"]["bus"]

        # Calculate global power quality
        mean_global_voltage = mean(bus["vm"] for bus in values(solved_bus))
        global_pq_avg = mean_global_voltage - ideal_nominal_voltage

        # Calcualte power quality through our target bus
        local_bus_voltage = solved_bus[string(meter_bus_id)]["vm"]
        local_pq = local_bus_voltage - ideal_bus_status[meter_bus_id]

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
        insert_record_sqlite(conn_sq, time_stamp, local_pq, is_converged, meter_bus_id)
        # peek_sqlite(conn_sq)
    end

    if USE_AWS_POSTGRES
        println("[db_population_poller] writing postgres")
        conn_pg = connect_pg()
        # Ensure schema exists in Postgres (mirror SQLite init)
        ensure_postgres_schema(conn_pg)
        insert_global_record_pg(conn_pg, time_stamp, global_pq_avg, num_islands, is_converged)
        insert_record_pg(conn_pg, time_stamp, local_pq, is_converged, meter_bus_id)
        # peek_pg(conn_pg)
        close_pg(conn_pg)
    end

    # Advance hourly index so sequence continues after any event interruption
    hourly_index += 1

    println("[db_population_poller] [$time_stamp] $(basename(next_file)) | converged=$(is_converged == 1) | islands=$num_islands | outage=$(is_converged == 0) | pq6=$local_pq | g_pq=$global_pq_avg | $status_str")

    sleep(reading_interval)
end
end

