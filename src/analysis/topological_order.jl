abstract type ChildExplorationResult end

struct Ok <: ChildExplorationResult end
struct Cycle <: ChildExplorationResult
	cycled_cells::Vector{Cell}
end

"Return a `TopologicalOrder` that lists the cells to be evaluated in a single reactive run, in topological order. Includes the given roots."
function topological_order(notebook::Notebook, topology::NotebookTopology, roots::Array{Cell,1}; allow_multiple_defs=false)::TopologicalOrder
	entries = Cell[]
	exits = Cell[]
	errable = Dict{Cell,ReactivityError}()

	# https://xkcd.com/2407/
	function bfs(cell::Cell)::ChildExplorationResult
		if cell in exits
			return Ok()
		elseif haskey(errable, cell)
			return Ok()
		elseif length(entries) > 0 && entries[end] == cell
			return Ok() # a cell referencing itself is legal
		elseif cell in entries
			currently_in = setdiff(entries, exits)
			cycle = currently_in[findfirst(isequal(cell), currently_in):end]

			if !cycle_is_among_functions(topology, cycle)
				for cell in cycle
					errable[cell] = CyclicReferenceError(topology, cycle)
				end
				return Cycle(cycle)
			end

			return Ok()
		end

		# used for cleanups of wrong cycles
		current_entries_num = length(entries)
		current_exits_num = length(exits)

		push!(entries, cell)

		assigners = where_assigned(notebook, topology, cell)
		if !allow_multiple_defs && length(assigners) > 1
			for c in assigners
				errable[c] = MultipleDefinitionsError(topology, c, assigners)
			end
		end
		referencers = where_referenced(notebook, topology, cell) |> Iterators.reverse
		for c in (allow_multiple_defs ? referencers : union(assigners, referencers))
			if c != cell
				child_result = bfs(c)

				# No cycle for this child or the cycle has no soft edges
				if child_result isa Ok || cell ∉ child_result.cycled_cells
					continue
				end

				# Can we cleanup the cycle from here or is it caused by a parent cell?
				# if the edge to the child cell is composed of soft assigments only then we can try to "break"
				# it else we bubble the result up to the parent until it is
				# either out of the cycle or a soft-edge is found
				if !is_soft_edge(topology, cell, c)
					# Cleanup all entries & child exits
					deleteat!(entries, current_entries_num+1:length(entries))
					deleteat!(exits, current_exits_num+1:length(exits))
					return child_result
				end

				# Cancel exploring this child (c)
				# 1. Cleanup the errables
				for cycled_cell in child_result.cycled_cells
					delete!(errable, cycled_cell)
				end
				# 2. Remove the current child (c) from the entries if it was just added
				if entries[end] == c
					pop!(entries)
				end

				continue # the cycle was created by us so we can keep exploring other childs
			end
		end
		push!(exits, cell)
		Ok()
	end

	# we first move cells to the front if they call `import` or `using`
	# we use MergeSort because it is a stable sort: leaves cells in order if they are in the same category
	prelim_order_1 = sort(roots, alg=MergeSort, by=c -> cell_precedence_heuristic(topology, c))
	# reversing because our search returns reversed order
	prelim_order_2 = Iterators.reverse(prelim_order_1)
	bfs.(prelim_order_2)
	ordered = reverse(exits)
	TopologicalOrder(topology, setdiff(ordered, keys(errable)), errable)
end

function topological_order(notebook::Notebook)
	cached = notebook._cached_topological_order
	if cached === nothing || cached.input_topology !== notebook.topology
		topological_order(notebook, notebook.topology, notebook.cells)
	else
		cached
	end
end

Base.collect(notebook_topo_order::TopologicalOrder) = union(notebook_topo_order.runnable, keys(notebook_topo_order.errable))

function disjoint(a::Set, b::Set)
	!any(x in a for x in b)
end

"Return the cells that reference any of the symbols defined by the given cell. Non-recursive: only direct dependencies are found."
function where_referenced(notebook::Notebook, topology::NotebookTopology, myself::Cell)::Array{Cell,1}
	to_compare = union(topology.nodes[myself].definitions, topology.nodes[myself].soft_definitions, topology.nodes[myself].funcdefs_without_signatures)
	where_referenced(notebook, topology, to_compare)
end
"Return the cells that reference any of the given symbols. Non-recursive: only direct dependencies are found."
function where_referenced(notebook::Notebook, topology::NotebookTopology, to_compare::Set{Symbol})::Array{Cell,1}
	return filter(notebook.cells) do cell
		!disjoint(to_compare, topology.nodes[cell].references)
	end
end

"Returns whether or not the edge between two cells is composed only of \"soft\"-definitions"
function is_soft_edge(topology::NotebookTopology, parent_cell::Cell, child_cell::Cell)
	hard_definitions = union(topology.nodes[parent_cell].definitions, topology.nodes[parent_cell].funcdefs_without_signatures)
	soft_definitions = topology.nodes[parent_cell].soft_definitions

	child_references = topology.nodes[child_cell].references

	disjoint(hard_definitions, child_references) && !disjoint(soft_definitions, child_references)
end


"Return the cells that also assign to any variable or method defined by the given cell. If more than one cell is returned (besides the given cell), then all of them should throw a `MultipleDefinitionsError`. Non-recursive: only direct dependencies are found."
function where_assigned(notebook::Notebook, topology::NotebookTopology, myself::Cell)::Array{Cell,1}
	self = topology.nodes[myself]
	return filter(notebook.cells) do cell
		other = topology.nodes[cell]
		!(
			disjoint(self.definitions,                 other.definitions) &&

			disjoint(self.definitions,                 other.funcdefs_without_signatures) &&
			disjoint(self.funcdefs_without_signatures, other.definitions) &&

			disjoint(self.funcdefs_with_signatures,    other.funcdefs_with_signatures)
		)
	end
end

function where_assigned(notebook::Notebook, topology::NotebookTopology, to_compare::Set{Symbol})::Array{Cell,1}
	filter(notebook.cells) do cell
		other = topology.nodes[cell]
		!(
			disjoint(to_compare, other.definitions) &&
			disjoint(to_compare, other.funcdefs_without_signatures)
		)
	end
end

"Return whether any cell references the given symbol. Used for the @bind mechanism."
function is_referenced_anywhere(notebook::Notebook, topology::NotebookTopology, sym::Symbol)::Bool
	any(notebook.cells) do cell
		sym ∈ topology.nodes[cell].references
	end
end

"Return whether any cell defines the given symbol. Used for the @bind mechanism."
function is_assigned_anywhere(notebook::Notebook, topology::NotebookTopology, sym::Symbol)::Bool
	any(notebook.cells) do cell
		sym ∈ topology.nodes[cell].definitions
	end
end

function cyclic_variables(topology::NotebookTopology, cycle::AbstractVector{Cell})::Set{Symbol}
	referenced_during_cycle = union!(Set{Symbol}(), (topology.nodes[c].references for c in cycle)...)
	assigned_during_cycle = union!(Set{Symbol}(), (topology.nodes[c].definitions ∪ topology.nodes[c].soft_definitions ∪ topology.nodes[c].funcdefs_without_signatures for c in cycle)...)
	
	referenced_during_cycle ∩ assigned_during_cycle
end

function cycle_is_among_functions(topology::NotebookTopology, cycle::AbstractVector{Cell})::Bool
	cyclics = cyclic_variables(topology, cycle)
	
	all(
		any(s ∈ topology.nodes[c].funcdefs_without_signatures for c in cycle)
		for s in cyclics
	)
end


"""Assigns a number to a cell - cells with a lower number might run first. 

This is used to treat reactive dependencies between cells that cannot be found using static code anylsis."""
function cell_precedence_heuristic(topology::NotebookTopology, cell::Cell)::Real
	top = topology.nodes[cell]
	if :Pkg ∈ top.definitions
		1
	elseif :DrWatson ∈ top.definitions
		2
	elseif Symbol("Pkg.API.activate") ∈ top.references || 
		Symbol("Pkg.activate") ∈ top.references ||
		Symbol("@pkg_str") ∈ top.references ||
		# https://juliadynamics.github.io/DrWatson.jl/dev/project/#DrWatson.quickactivate
		Symbol("quickactivate") ∈ top.references ||
		Symbol("@quickactivate") ∈ top.references ||
		Symbol("DrWatson.@quickactivate") ∈ top.references ||
		Symbol("DrWatson.quickactivate") ∈ top.references
		3
	elseif Symbol("Pkg.API.add") ∈ top.references ||
		Symbol("Pkg.add") ∈ top.references ||
		Symbol("Pkg.API.develop") ∈ top.references ||
		Symbol("Pkg.develop") ∈ top.references
		4
	elseif :LOAD_PATH ∈ top.references
		# https://github.com/fonsp/Pluto.jl/issues/323
		5
	elseif :Revise ∈ top.definitions
		# Load Revise before other packages so that it can properly `revise` them.
		6
	elseif !isempty(topology.codes[cell].module_usings_imports.usings)
		# always do `using X` before other cells, because we don't (yet) know which cells depend on it (we only know it with `import X` and `import X: y, z`)
		7
	elseif :include ∈ top.references
		# https://github.com/fonsp/Pluto.jl/issues/193
		# because we don't (yet) know which cells depend on it
		8
	else
		DEFAULT_PRECEDENCE_HEURISTIC
	end
end

const DEFAULT_PRECEDENCE_HEURISTIC = 9
