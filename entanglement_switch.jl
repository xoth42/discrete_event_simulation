using ResumableFunctions, ConcurrentSim, Plots, Random, Distributions

wait_timeout = 0

# # Entanglement Switch

# An entanglement swtich is a node in a quantum network that creates entanglement with
# some end nodes, and then performs measurements on its entangled qubits to create
# entanglement between the end nodes (a process we will refer to as "entanglement swapping",
# slightly abusing terminology).
# Creating and storing entanglement between the switch and end nodes requires a qubit,
# and the switch only has a limited number of qubits.
#
# We model the switch using a structure that tracks available qubits and entanglement.
# Moreover, we track "entanglement tickets": we allow a process to claim such a ticket,
# which gives it ownership of a particular entangled state.
# This allows it to claim entanglement before the process is actually ready to consume it
# through entanglement swapping.
#
# We will simulate the dynamics of entanglement being consumed according to swapping
# requests, which are made by the end nodes over the course of the simulation.
# We give the switch fields to track how many requests are currently open and how many have
# been fulfilled in total.
mutable struct EntanglementSwitch
    env::Environment
    qubits::Resource
    entanglements::Vector{Int}
    entanglement_tickets::Store{Int}
    num_open_requests::Int
    num_fulfilled_requests::Int
    """
    we use an inner constructor: you only need to provide the environment and the number
    of qubits when creating a new switch instance.
    """
    function EntanglementSwitch(env::Environment, num_qubits::Int)
        new(env, Resource(env, num_qubits, level=num_qubits), Int[],
            Store{Int}(env; capacity=num_qubits), 0, 0)
    end
end

# We will have independent processes that create and consume entanglement, and will study
# the emergent dynamics of the switch.
# An entangler process continuously tries to claim qubits and use them to create
# entanglement with one particular end node.
# Trying to entangling a qubit with an end node takes one time step,
# but it is hard and only succeeds with a small probability.
# Therefore, the amount of time until success is geometrically distributed.
# ent_success_times = []

# function throwaway!(wait_timeout,open_req_wait,switch) 
#     # throw it all away hack
#     # println("throwing away ent")
#     switch.entanglements = []
#     switch.qubits.level = switch.qubits.capacity
#     wait_timeout = 0
#     open_req_wait = 0
# end

@resumable function entangler(env::Environment, switch::EntanglementSwitch,
        success_probability::Float64, end_node::Int)
    
    global wait_timeout = 0
    # open_req_wait = 0

    while true
        # reset the open_req_wait if requests are under the threshold
        # if env.num_open_requests <= max_open_requests
        #     open_req_wait = 0
        #     wait_timeout = 0
        # end
        if (switch.qubits.level == 0)
            # check if requests are piling up
            # if env.num_open_requests > max_open_requests
            #     # Too many requests at max level
            #     # wait for this case a few times before doing anything
            #     if open_req_wait > max_open_requests_wait
            #         # Ok fine now throw away
            #         throwaway!(wait_timeout,open_req_wait,switch)
            #     else
            #         open_req_wait += 1
            #     end
            # # requests might not be maxing, but the wait may be max
            if (wait_timeout > max_wait_timeout) || (switch.num_open_requests > max_open_requests) #normal wait times (longer time untill throwaway)
                # throwaway!(wait_timeout,open_req_wait,switch)
                    # throw it all away hack
                # println("throwing away ent")
                switch.entanglements = []
                switch.qubits.level = switch.qubits.capacity
                wait_timeout = 0
            else
                # increment the timeout 
                wait_timeout += 1
            end
        else 
            @yield get(switch.qubits, 1)
            duration = rand(Geometric(success_probability)) + 1
            @yield timeout(env, duration)
            # println("$(now(env)): entanglement $end_node created")
            push!(switch.entanglements, end_node)
            put!(switch.entanglement_tickets, end_node)
            push!(ent_success_times,duration)
            # println("Entanglement: $(switch.entanglements)")
        end
    end
end
# A request fulfiller takes one specific swapping request and becomes resonsible for
# fulfilling it. It claims entanglement tickets corresponding to the end nodes
# that want to be entanglement, and performs the swap once all relevant tickets
# are obtained.
@resumable function request_fulfiller(env::Environment, switch::EntanglementSwitch,
        request::Vector{Int})
    # println("Request: $request")
    switch.num_open_requests += 1

    entanglement_tickets =
        [get(switch.entanglement_tickets, isequal(i)) for i in request]
    @yield AllOf(entanglement_tickets...)
    for end_node in request  # consume the entanglement it holds tickets for
        if !isnothing(findfirst(isequal(end_node), switch.entanglements))
        deleteat!(switch.entanglements,
            findfirst(isequal(end_node), switch.entanglements))
        end
    end
    put!(switch.qubits, length(request)) # release the qubits that held the entangled states
    switch.num_open_requests -= 1 # log that we have successfully fulfilled the request
    switch.num_fulfilled_requests += 1
end
# Finally, there we make a requester process that randomly generates and issues requests.

@resumable function requester(env::Environment, switch::EntanglementSwitch,
        num_end_nodes_total, num_end_nodes_per_request, request_rate)
    distribution = Exponential(1 / request_rate)
    while true
        if switch.num_open_requests > 10000
            throw("Too many open requests at time $(now(env)), unstable system!")
        end
        @yield timeout(env, rand(distribution))
        request = randperm(num_end_nodes_total)[1:num_end_nodes_per_request]
        #md println("$(now(env)): new request $request")
        @process request_fulfiller(env, switch, request)
    end
end

# Let's set up some parameters and run the simulation!

# set up parameters

# num_communication_qubits = 8
# num_end_nodes = 3
# request_rates = [0.05, 0.01]  # entanglement between 2, 3, ... end nodes
# success_probabilities = [0.1, 0.1, 0.1]

# initialize the simulation


function run_sum_config(max_wait_timeout,max_open_requests;max_time=10000,    t_print=100,num_communication_qubits = 8,num_end_nodes = 3,request_rates = [0.05, 0.01],success_probabilities = [0.1, 0.1, 0.1])
        
    sim = Simulation()
    switch = EntanglementSwitch(sim, num_communication_qubits)
    [@process requester(sim, switch, num_end_nodes, i + 1, request_rates[i])
        for i in eachindex(request_rates)]
    [@process entangler(sim, switch, success_probabilities[i], i) for i in 1:num_end_nodes]

    # run it!
    open_reqs = []
    fulfilled_reqs = []
    qubits = []
    ts = 1:10:max_time
    wait_timeouts = []

    # create a param to minimize, which will be the integral of the open requests, over the simulation step
    failure_tot = 0

    for t in ts
        # (t % t_print == 11 || t == 1) && println("t: $t")
        push!(wait_timeouts,wait_timeout)
        push!(qubits,switch.qubits.level)
        push!(open_reqs, switch.num_open_requests)
        push!(fulfilled_reqs, switch.num_fulfilled_requests)
        failure_tot += switch.num_open_requests
        run(sim, t)
    end
    return failure_tot,ts,open_reqs,fulfilled_reqs,wait_timeouts
end

# max_wait_timeout = 20
# max_open_requests = 250
# max_time = 10000
# # max_time = 1000
# # max_time = 500

# failure_tot,ts,open_reqs,fulfilled_reqs,wait_timeouts = run_sum_config(max_wait_timeout,max_open_requests;max_time=10000)

# # Visualize how the number of open and fulfilled requests changes over time.
# plot(ts, fulfilled_reqs, label="Fulfilled Requests", xlabel="Simulation Step",
#     ylabel="Number of Requests")
# plot!(ts, open_reqs, label="Open Requests", xlabel="Simulation Step")
# plot!([0,max_time],[max_open_requests,max_open_requests],label="Max open requests without qubits available")
# plot!(ts,wait_timeouts,label="Wait timeout counter")
# p = plot!([0,max_time],[max_wait_timeout,max_wait_timeout],label="Max open wait timeouts")

# # gui(p)
# # What is going wrong?
# # Do you have ideas how to fix it?

# # Same thing without fulfulled requests
# plot(ts, open_reqs, label="Open Requests", xlabel="Simulation Step")
# # plot(ts, failure_amt, label="total failed request time")
# plot!([0,max_time],[max_open_requests,max_open_requests],label="Max open requests without qubits available")
# plot!(ts,wait_timeouts,label="Wait timeout counter")
# plot!([0,max_time],[max_wait_timeout,max_wait_timeout],label="Max open wait timeouts",show=true)



# plot(ts, qubits, label="qubits", xlabel="Simulation Step",show=true)


# plot(ts, qubits, label="qubits", xlabel="Simulation Step",show=true)


# lets optimize this
using Optim
using LinearAlgebra
# using SparseArrays
# using CairoMakie
# using Piccolo

# function to minimize:
function optimize_wrapper(max_wait_timeout,max_open_requests)
    
    failure_tot,ts,open_reqs,fulfilled_reqs,wait_timeouts = run_sum_config(max_wait_timeout,max_open_requests;max_time=10000)
    println("fail: $failure_tot, \tmax_wait_timeout: $max_wait_timeout, \tmax_open_requests:$max_open_requests")
    return failure_tot
end

#max_wait_timeout,max_open_requests
x0 = [20.0,250.0]
f = (x) -> optimize_wrapper(x[1],x[2])
optimize(f,x0)
