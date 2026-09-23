/*---------------------------------------------------------------------------*\
  OpenFOAM linear-solver adapter for NVIDIA AmgX.
\*---------------------------------------------------------------------------*/

#ifndef AmgXSolver_H
#define AmgXSolver_H

#include "lduMatrix.H"

namespace Foam
{

class AmgXSolver
:
    public lduMatrix::solver
{
public:

    TypeName("AmgX");

    AmgXSolver
    (
        const word& fieldName,
        const lduMatrix& matrix,
        const Field<Field<scalar>>& interfaceBouCoeffs,
        const Field<Field<scalar>>& interfaceIntCoeffs,
        const lduInterfaceFieldPtrsList& interfaces,
        const dictionary& solverControls
    );

    AmgXSolver(const AmgXSolver&) = delete;

    virtual ~AmgXSolver()
    {}

    virtual solverPerformance solve
    (
        scalarField& psi,
        const scalarField& source,
        const direction cmpt = 0
    ) const;

    void operator=(const AmgXSolver&) = delete;
};

} // End namespace Foam

#endif

// ************************************************************************* //

