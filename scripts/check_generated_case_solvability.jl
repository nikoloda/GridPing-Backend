using PowerModels
using Ipopt
using JuMP

# 1. Silence PowerModels (Memento.jl) warnings globally
PowerModels.silence()

const CASE_DIR = abspath(joinpath(@__DIR__, "..", "cases", "transmission", "generated_cases"))
const CASE_FILES = sort(filter(f -> startswith(f, "hourly_case_") && endswith(f, ".m"), readdir(CASE_DIR)))
const ACCEPTED_STATUSES = Set(["LOCALLY_SOLVED", "ALMOST_LOCALLY_SOLVED", "OPTIMAL"])

function solve_case(case_path::AbstractString)
    local network = nothing
    local result = nothing
    local status = "UNKNOWN"
    local solvable = false
    local detail = "no solution"

    try
        network = PowerModels.parse_file(case_path)
        
        # Configure a completely silent Ipopt solver
        silent_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)
        
        # Pass the silent solver into the OPF runner
        result = solve_ac_opf(network, silent_solver)
        
    catch err
        return (solvable = false, status = "ERROR", detail = sprint(showerror, err))
    end

    status = haskey(result, "termination_status") ? string(result["termination_status"]) : "UNKNOWN"
    has_solution = haskey(result, "solution") && !isempty(result["solution"])
    solvable = has_solution && (status in ACCEPTED_STATUSES)
    detail = has_solution ? "solution present" : "no solution"

    return (solvable = solvable, status = status, detail = detail)
end

println("Checking cases in $CASE_DIR")
println("Using accepted statuses: $(collect(ACCEPTED_STATUSES))")

solvable_cases = String[]
unsolvable_cases = String[]

for case_file in CASE_FILES
    case_path = joinpath(CASE_DIR, case_file)
    result = solve_case(case_path)
    verdict = result.solvable ? "SOLVABLE" : "NOT SOLVABLE"
    println("[$verdict] $case_file | status=$(result.status) | $(result.detail)")

    if result.solvable
        push!(solvable_cases, case_file)
    else
        push!(unsolvable_cases, case_file)
    end
end

println("\nSummary:")
println("  Solvable: $(length(solvable_cases))")
println("  Not solvable: $(length(unsolvable_cases))")

if !isempty(unsolvable_cases)
    println("\nUnsolvable cases:")
    for case_file in unsolvable_cases
        println("  - $case_file")
    end
end