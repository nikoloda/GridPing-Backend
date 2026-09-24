using PowerModels
using Ipopt

# 1. Define the 24-hour diurnal load curve
load_curve = [
    0.50, 0.45, 0.45, 0.50, 0.60, 0.75, 0.85, 0.90, 0.95, 0.95, 0.95, 0.95, 
    0.95, 0.95, 0.95, 0.95, 0.95, 1.00, 0.95, 0.90, 0.80, 0.70, 0.60, 0.55
]

# Load the base case and create the output directory
network = PowerModels.parse_file("cases/transmission/case2383wp.m")
output_dir = "cases/transmission/generated_cases"
mkpath(output_dir)

# 2. Raw solver initialization (Warning: This will print the Ipopt log to the console)
solver = Ipopt.Optimizer

for hour in 1:24
    # Create a fresh network state for this specific hour
    variant = deepcopy(network)
    
    # Scale the load for the current hour
    for (load_id, load) in variant["load"]
        load["pd"] *= load_curve[hour]
        load["qd"] *= load_curve[hour] 
    end
    
    # Relax Generator Pmin to prevent over-generation infeasibility
    for (gen_id, gen) in variant["gen"]
        if gen["pmin"] > 0
            gen["pmin"] = 0.0
        end
    end
    
    # 3. Run Optimal Power Flow using the raw solver
    result = solve_ac_opf(variant, solver)
    status_string = string(result["termination_status"])
    
    # Robust string-based status check 
    if status_string in ["LOCALLY_SOLVED", "ALMOST_LOCALLY_SOLVED", "OPTIMAL"]
        # Merge the solved states back into the dictionary
        PowerModels.update_data!(variant, result["solution"])
        
        # Save the physically accurate state
        PowerModels.export_matpower(joinpath(output_dir, "diurnal_hour_$hour.m"), variant)
        println("Hour $hour: Successfully dispatched and solved.")
    else
        println("Hour $hour: FAILED. Status code: ", status_string)
    end
end