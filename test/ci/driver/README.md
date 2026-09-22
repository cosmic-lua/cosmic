# CI driver source

`cosmic_ci/` is an ordinary Teal namespace copied byte-for-byte into a fresh
external project by `../bootstrap-driver.sh`. The verified runner remains
outside both that project and the candidate checkout. `testdata/` contains
fixture input and is explicitly excluded from module and test discovery.

`../check-driver.sh` receives the source checkout explicitly, bootstraps the
project, and invokes absolute copied test paths with the verified host. The
candidate checkout is passed only to tests and orchestration as a child
subject. Runner operation state stays in a separately checked external
database. The checked-in pin is the production trust root; local development
may preseed a temporary pin cache with a digest-verified locally built host,
but that does not establish release publication or immutability.

Orchestration copies the bootstrapped `cosmic_ci/` namespace once into one
external fixture project. Each fixture invocation uses the verified host with
an explicit selected test path, a fresh project database, and distinct
temporary and diagnostic directories. Setup modules construct artifacts;
ordinary `*_test.tl` modules verify them and parse a fresh result. Fixture
program sources live as ordinary `.tl` data under `testdata/`.
