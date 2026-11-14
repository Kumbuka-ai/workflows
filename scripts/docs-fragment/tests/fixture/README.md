<!--
Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
All rights reserved. Copying, reproduction, distribution or any other
use of this file, in whole or in part, without the prior written
permission of the copyright holder is prohibited.
-->
# Fixture of the docs-fragment tests

A small Maven reactor with a Dockerfile, copied into a fresh git repository by
`../generate.test.sh` and `../publish.test.sh`. Nothing here is ever built. This
file is tracked but is no build manifest, so it must not appear in the
fragment's build structure.
