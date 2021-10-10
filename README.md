# An API client for docker written in Haskell

## Current state

Supported Docker Engine Api version: `v1.24` and onwards.

Anything upward of that should work since Docker versions their API.
Older docker version and engine api versions are not supported at the moment.

## Documentation

The API-documentation is available at
[Hackage](https://hackage.haskell.org/package/docker). There are also some
usage-examples in the main library source file,
[`Client.hs`](https://hackage.haskell.org/package/docker/docs/Docker-Client.html).

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md).

### Project Setup

For working on the library, you need the Haskell Tool Stack installed (see [the
Haskell Tool Stack
website](https://docs.haskellstack.org/en/stable/install_and_upgrade/)). You
also need `make` to use the `Makefile` included in the project. Run `make help`
to see the available commands (for building, running the tests and releasing).

### Tests

Tests are located in the `tests` directory and can be run with `make test`. This
only runs the unit tests.

To run integration tests, you need Docker installed and listening on Port `2375`
of `localhost` (docker only listens to a Unix socket by default, see the [Docker
documentation](https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-socket-option)
for details). Set the environment variable `RUN_INTEGRATION_TESTS`, i.e.
`RUN_INTEGRATION_TESTS=1 make test`.
