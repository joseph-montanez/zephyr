# Trim and tessellation oracle scripts

These independent Python scripts generate golden expectations for the spline-trim
rendering investigation. They are diagnostic oracles, not part of the test suite.

- `eab_probe.py`: decodes two-spline/line EAB verification files and prints their
  stored entity geometry.
- `spline_exact.py`: solves the diagnostic cubic spline's crossing with
  `y = -148` using `mpmath` at 50-digit precision. It requires `mpmath`.
- `render_cross.py`: compares uniform and adaptive chord crossings for the same
  spline using ordinary double precision.

The diagnostic golden result is the right-branch spline crossing at
`t = 0.8151785877944898857`, with `x = 121.69301292060802241` and `y = -148`.

The existing ordinary-precision scripts should not be rewritten to approximate
the application's own implementation: they serve as an independent numerical
check. Promote their numeric expectations into Swift tests as literals, with a
provenance comment pointing back to these scripts.
