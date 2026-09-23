/*---------------------------------------------------------------------------*\
  OpenFOAM linear-solver adapter for NVIDIA AmgX.

  This adapter intentionally supports serial, uncoupled ldu matrices. CPU MPI
  remains available through OpenFOAM's native Pstream solvers. Distributed
  AmgX requires global numbering and halo exchange and must not be emulated by
  independently solving each MPI partition.
\*---------------------------------------------------------------------------*/

#include "AmgXSolver.H"
#include "Pstream.H"
#include "addToRunTimeSelectionTable.H"
#include "amgx_c.h"

#include <climits>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string>

namespace Foam
{
    defineTypeNameAndDebug(AmgXSolver, 0);

    lduMatrix::solver::addsymMatrixConstructorToTable<AmgXSolver>
        addAmgXSymMatrixConstructorToTable_;

    lduMatrix::solver::addasymMatrixConstructorToTable<AmgXSolver>
        addAmgXAsymMatrixConstructorToTable_;
}

namespace
{

void checkAmgX(const AMGX_RC status, const char* operation)
{
    if (status != AMGX_RC_OK)
    {
        FatalErrorInFunction
            << "NVIDIA AmgX operation failed: " << operation
            << " (status " << int(status) << ')'
            << exit(FatalError);
    }
}

}


Foam::AmgXSolver::AmgXSolver
(
    const word& fieldName,
    const lduMatrix& matrix,
    const Field<Field<scalar>>& interfaceBouCoeffs,
    const Field<Field<scalar>>& interfaceIntCoeffs,
    const lduInterfaceFieldPtrsList& interfaces,
    const dictionary& solverControls
)
:
    lduMatrix::solver
    (
        fieldName,
        matrix,
        interfaceBouCoeffs,
        interfaceIntCoeffs,
        interfaces,
        solverControls
    )
{}


Foam::solverPerformance Foam::AmgXSolver::solve
(
    scalarField& psi,
    const scalarField& source,
    const direction cmpt
) const
{
    static_assert(sizeof(scalar) == sizeof(double),
        "AmgXSolver requires an OpenFOAM DP build");
    static_assert(sizeof(label) == sizeof(int),
        "AmgXSolver requires an OpenFOAM Int32 build");

    if (Pstream::parRun())
    {
        FatalErrorInFunction
            << "The AmgX adapter is single-process only. Use an OpenFOAM "
            << "CPU solver for MPI runs, or launch the GPU case with one rank."
            << exit(FatalError);
    }

    forAll(interfaces_, interfacei)
    {
        if (interfaces_.set(interfacei))
        {
            FatalErrorInFunction
                << "The AmgX adapter does not yet support coupled matrix "
                << "interfaces (cyclic, processor, or mapped coupling)."
                << exit(FatalError);
        }
    }

    solverPerformance solverPerf(typeName, fieldName_);
    const label nCells = psi.size();
    const label nFaces = matrix_.upper().size();

    if (nCells > INT_MAX || nFaces > (INT_MAX - nCells)/2)
    {
        FatalErrorInFunction
            << "The AmgX dDDI mode uses 32-bit indices and this matrix is too large."
            << exit(FatalError);
    }

    scalarField Apsi(nCells);
    matrix_.Amul(Apsi, psi, interfaceBouCoeffs_, interfaces_, cmpt);
    scalarField residual(source - Apsi);
    scalarField normalisationWork(nCells);
    const scalar normFactor = normFactor(psi, source, Apsi, normalisationWork);

    solverPerf.initialResidual() = gSum(mag(residual))/normFactor;
    solverPerf.finalResidual() = solverPerf.initialResidual();

    if
    (
        minIter_ == 0
     && solverPerf.checkConvergence(tolerance_, relTol_)
    )
    {
        return solverPerf;
    }

    List<int> rowOffsets(nCells + 1, 0);
    const labelUList& upperAddress = matrix_.lduAddr().upperAddr();
    const labelUList& lowerAddress = matrix_.lduAddr().lowerAddr();

    for (label face = 0; face < nFaces; ++face)
    {
        ++rowOffsets[upperAddress[face] + 1];
        ++rowOffsets[lowerAddress[face] + 1];
    }
    for (label cell = 0; cell < nCells; ++cell)
    {
        rowOffsets[cell + 1] += rowOffsets[cell] + 1;
    }

    const int nNonZeros = rowOffsets[nCells];
    List<int> columns(nNonZeros);
    List<int> cursor(rowOffsets);
    List<double> coefficients(nNonZeros);

    const scalarField& diagonal = matrix_.diag();
    const scalarField& upper = matrix_.upper();
    const scalarField& lower = matrix_.lower();

    for (label cell = 0; cell < nCells; ++cell)
    {
        const int entry = cursor[cell]++;
        columns[entry] = int(cell);
        coefficients[entry] = diagonal[cell];
    }
    for (label face = 0; face < nFaces; ++face)
    {
        const label upperCell = upperAddress[face];
        const label lowerCell = lowerAddress[face];

        int entry = cursor[upperCell]++;
        columns[entry] = int(lowerCell);
        coefficients[entry] = lower[face];

        entry = cursor[lowerCell]++;
        columns[entry] = int(upperCell);
        coefficients[entry] = upper[face];
    }

    const string configFile
    (
        controlDict_.lookupOrDefault<string>("amgxConfigFile", string::null)
    );

    // std::to_string rounds at six decimal places and would turn common
    // tolerances such as 1e-7 into zero. Preserve the scalar value exactly.
    std::ostringstream configStream;
    configStream
        << std::setprecision(std::numeric_limits<double>::max_digits10)
        << "{\"config_version\":2,\"solver\":{"
        << "\"solver\":\"FGMRES\","
        << "\"preconditioner\":{\"solver\":\"AMG\","
        << "\"algorithm\":\"AGGREGATION\",\"max_iters\":1,"
        << "\"presweeps\":1,\"postsweeps\":1,\"cycle\":\"V\"},"
        << "\"max_iters\":" << maxIter_ << ','
        << "\"tolerance\":" << tolerance_ << ','
        << "\"norm\":\"L2\",\"monitor_residual\":1,"
        << "\"print_solve_stats\":0}}";
    const std::string generatedConfig(configStream.str());

    AMGX_config_handle config = {};
    AMGX_resources_handle resources = {};
    AMGX_matrix_handle matrix = {};
    AMGX_vector_handle rhs = {};
    AMGX_vector_handle solution = {};
    AMGX_solver_handle solver = {};

    checkAmgX(AMGX_initialize(), "AMGX_initialize");
    if (configFile.empty())
    {
        checkAmgX
        (
            AMGX_config_create(&config, generatedConfig.c_str()),
            "AMGX_config_create"
        );
    }
    else
    {
        checkAmgX
        (
            AMGX_config_create_from_file(&config, configFile.c_str()),
            "AMGX_config_create_from_file"
        );
    }

    checkAmgX
    (
        AMGX_resources_create_simple(&resources, config),
        "AMGX_resources_create_simple"
    );
    checkAmgX
    (
        AMGX_matrix_create(&matrix, resources, AMGX_mode_dDDI),
        "AMGX_matrix_create"
    );
    checkAmgX
    (
        AMGX_vector_create(&rhs, resources, AMGX_mode_dDDI),
        "AMGX_vector_create(rhs)"
    );
    checkAmgX
    (
        AMGX_vector_create(&solution, resources, AMGX_mode_dDDI),
        "AMGX_vector_create(solution)"
    );
    checkAmgX
    (
        AMGX_solver_create(&solver, resources, AMGX_mode_dDDI, config),
        "AMGX_solver_create"
    );
    checkAmgX
    (
        AMGX_matrix_upload_all
        (
            matrix,
            int(nCells),
            nNonZeros,
            1,
            1,
            rowOffsets.begin(),
            columns.begin(),
            coefficients.begin(),
            nullptr
        ),
        "AMGX_matrix_upload_all"
    );
    checkAmgX
    (
        AMGX_vector_upload(rhs, int(nCells), 1, source.begin()),
        "AMGX_vector_upload(rhs)"
    );
    checkAmgX
    (
        AMGX_vector_upload(solution, int(nCells), 1, psi.begin()),
        "AMGX_vector_upload(solution)"
    );
    checkAmgX(AMGX_solver_setup(solver, matrix), "AMGX_solver_setup");
    checkAmgX(AMGX_solver_solve(solver, rhs, solution), "AMGX_solver_solve");
    checkAmgX
    (
        AMGX_vector_download(solution, psi.begin()),
        "AMGX_vector_download"
    );

    int iterations = 0;
    checkAmgX
    (
        AMGX_solver_get_iterations_number(solver, &iterations),
        "AMGX_solver_get_iterations_number"
    );
    solverPerf.nIterations() = iterations;

    checkAmgX(AMGX_solver_destroy(solver), "AMGX_solver_destroy");
    checkAmgX(AMGX_vector_destroy(solution), "AMGX_vector_destroy(solution)");
    checkAmgX(AMGX_vector_destroy(rhs), "AMGX_vector_destroy(rhs)");
    checkAmgX(AMGX_matrix_destroy(matrix), "AMGX_matrix_destroy");
    checkAmgX(AMGX_resources_destroy(resources), "AMGX_resources_destroy");
    checkAmgX(AMGX_config_destroy(config), "AMGX_config_destroy");
    checkAmgX(AMGX_finalize(), "AMGX_finalize");

    matrix_.Amul(Apsi, psi, interfaceBouCoeffs_, interfaces_, cmpt);
    residual = source - Apsi;
    solverPerf.finalResidual() = gSum(mag(residual))/normFactor;

    return solverPerf;
}

// ************************************************************************* //

