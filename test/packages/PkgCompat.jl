import Pluto.PkgCompat
import Pluto
import Pluto: update_save_run!, update_run!, WorkspaceManager, ClientSession, ServerSession, Notebook, Cell, project_relative_path, SessionActions, load_notebook
using Test
import Pkg


@testset "PkgCompat" begin

    @testset "Available versions" begin
        vs = PkgCompat.package_versions("HTTP")

        @test v"0.9.0" ∈ vs
        @test v"0.9.1" ∈ vs
        @test "stdlib" ∉ vs
        @test PkgCompat.package_exists("HTTP")

        vs = PkgCompat.package_versions("Dates")

        @test vs == ["stdlib"]
        @test PkgCompat.package_exists("Dates")

        @test PkgCompat.is_stdlib("Dates")
        @test !PkgCompat.is_stdlib("PlutoUI")


        vs = PkgCompat.package_versions("Dateskjashdfkjahsdfkjh")

        @test isempty(vs)
        @test !PkgCompat.package_exists("Dateskjashdfkjahsdfkjh")
    end

    @testset "Installed versions" begin
        # we are querying the package environment that is currently active for testing
        ctx = Pkg.Types.Context()

        ctx = PkgCompat.create_empty_ctx()
        Pkg.add(ctx, [Pkg.PackageSpec("HTTP"), Pkg.PackageSpec("UUIDs"), ])
        @test PkgCompat.get_manifest_version(ctx, "HTTP") > v"0.8.0"
        @test PkgCompat.get_manifest_version(ctx, "UUIDs") == "stdlib"

    end

    @testset "Completions" begin
        cs = PkgCompat.package_completions("Hyper")
        @test "HypertextLiteral" ∈ cs
        @test "Hyperscript" ∈ cs

        cs = PkgCompat.package_completions("Date")
        @test "Dates" ∈ cs

        cs = PkgCompat.package_completions("Dateskjashdfkjahsdfkjh")

        @test isempty(cs)
    end

    @testset "Compat manipulation" begin
        old_path = joinpath(@__DIR__, "old_artifacts_import.jl")
        old_contents = read(old_path, String)
        
        dir = mktempdir()
        path = joinpath(dir, "hello.jl")
        
        write(path, old_contents)
        
        notebook = load_notebook(path)
        ptoml_contents() = PkgCompat.read_project_file(notebook)
        mtoml_contents() = PkgCompat.read_manifest_file(notebook)
        
        @test num_backups_in(dir) == 0
        
        
        
        @test Pluto.only_versions_or_lineorder_differ(old_path, path)
        
        ptoml = Pkg.TOML.parse(ptoml_contents())
        @test haskey(ptoml["deps"], "PlutoPkgTestA")
        @test haskey(ptoml["deps"], "Artifacts")
        @test haskey(ptoml["compat"], "PlutoPkgTestA")
        @test haskey(ptoml["compat"], "Artifacts")
        
        notebook.nbpkg_ctx = PkgCompat.clear_stdlib_compat_entries(notebook.nbpkg_ctx)
        
        ptoml = Pkg.TOML.parse(ptoml_contents())
        @test haskey(ptoml["deps"], "PlutoPkgTestA")
        @test haskey(ptoml["deps"], "Artifacts")
        @test haskey(ptoml["compat"], "PlutoPkgTestA")
        if PkgCompat.is_stdlib("Artifacts")
            @test !haskey(ptoml["compat"], "Artifacts")
        end
        
        old_a_compat_entry = ptoml["compat"]["PlutoPkgTestA"]
        notebook.nbpkg_ctx = PkgCompat.clear_auto_compat_entries(notebook.nbpkg_ctx)
        
        ptoml = Pkg.TOML.parse(ptoml_contents())
        @test haskey(ptoml["deps"], "PlutoPkgTestA")
        @test haskey(ptoml["deps"], "Artifacts")
        @test !haskey(ptoml, "compat")
        compat = get(ptoml, "compat", Dict())
        @test !haskey(compat, "PlutoPkgTestA")
        @test !haskey(compat, "Artifacts")
        
        notebook.nbpkg_ctx = PkgCompat.write_auto_compat_entries(notebook.nbpkg_ctx)
        
        ptoml = Pkg.TOML.parse(ptoml_contents())
        @test haskey(ptoml["deps"], "PlutoPkgTestA")
        @test haskey(ptoml["deps"], "Artifacts")
        @test haskey(ptoml["compat"], "PlutoPkgTestA")
        if PkgCompat.is_stdlib("Artifacts")
            @test !haskey(ptoml["compat"], "Artifacts")
        end
        
        
    end
    
    
    @testset "Misc" begin
        PkgCompat.create_empty_ctx()
    end
end
