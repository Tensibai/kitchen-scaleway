# Contributing

Pull requests are very welcome.

* Source is hosted on [GitHub](https://github.com/test-kitchen/kitchen-scaleway).
* Report issues and feature requests on [GitHub Issues](https://github.com/test-kitchen/kitchen-scaleway/issues).
* Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting set up

```bash
git clone https://github.com/test-kitchen/kitchen-scaleway.git
cd kitchen-scaleway
bundle install
```

You do not need a Scaleway account or an API key to work on this driver. The
test suite never talks to the network.

## Rake tasks

| Command | What it does |
| --- | --- |
| `bundle exec rake` | Run tests and style. The same gates CI applies. |
| `bundle exec rake test` | Run the unit tests. |
| `bundle exec rake coverage` | Run the unit tests with coverage reporting. |
| `bundle exec rake style` | Run Cookstyle/Chefstyle. |
| `bundle exec rake style:auto_correct` | Fix the style offences that can be fixed automatically. |
| `bundle exec rake yard` | Build the API documentation into `doc/`. |
| `bundle exec rake yard:stats` | Report which objects are missing documentation. |
| `bundle exec rake yard:server` | Browse the documentation at `http://localhost:8808`. |

Run a single file or example while you iterate:

```bash
bundle exec rspec spec/kitchen/driver/scaleway_spec.rb
bundle exec rspec spec/kitchen/driver/scaleway_spec.rb:142
```

## How the tests work

The suite is entirely offline. Every Scaleway API call is stubbed with
[WebMock](https://github.com/bblimke/webmock), and `WebMock.disable_net_connect!`
turns an unstubbed request into a failure rather than letting it reach the
network. The suite never creates an Instance and never needs credentials.

```text
spec/
├── kitchen/driver/
│   ├── scaleway_spec.rb            the driver
│   └── scaleway_version_spec.rb    the version constant
├── readme_spec.rb                  keeps README tables in sync with the code
├── spec_helper.rb                  RSpec, WebMock and coverage configuration
└── support/
    ├── scaleway_api.rb             API payload builders and request stubs
    └── kitchen_helpers.rb          builds a driver the way Test Kitchen does
```

Three conventions are worth knowing before you add a test.

### Build the driver with `build_driver`

`build_driver` runs the real `finalize_config!` lifecycle hook rather than
stubbing `Kitchen::Driver::Base#instance`, so `required_config` validation and
the lazy `default_config` blocks stay on the code path under test:

```ruby
driver = build_driver(zone: "nl-ams-2", commercial_type: "DEV1-S")
```

It also defaults `server_wait_interval` to `0`, which is why the suite finishes
in under a second despite exercising both polling loops. Pass a custom instance
as the second argument when the platform or instance name matters:

```ruby
driver = build_driver({}, kitchen_instance(platform: "debian-13"))
```

Both arguments are positional on purpose. A keyword parameter would make Ruby
bind `build_driver(username: "admin")` to the keyword instead of to the config
hash.

### Build API payloads, do not record them

`spec/support/scaleway_api.rb` builds responses in code so an example can
describe exactly the state it needs:

```ruby
stub_server_create(server: server_payload(status: "starting"))
stub_server_find(id: "server-1234", servers: [
  server_payload(status: "starting"),
  server_payload(status: "started", ip: "1.2.3.4"),
])
stub_server_delete(id: "server-1234")
```

Each stub returns a documented JSON payload, and `server_payload` grows a
`status:` and `ip:` keyword so a test never has to hand-write a full Server
object.

### Set the environment inline and let the hook clean up

The driver reads `SCW_*` environment variables. `spec_helper.rb` snapshots and
restores `ENV` around every example, so set what you need inline and let the
hook clean up:

```ruby
it "reads the zone from SCW_DEFAULT_ZONE" do
  ENV["SCW_DEFAULT_ZONE"] = "nl-ams-1"

  expect(build_driver({})[:zone]).to eq("nl-ams-1")
end
```

The suite runs in random order and must pass at any seed. If a change makes it
order dependent, `bundle exec rspec --seed 1234` will usually surface it.

### Coverage

```bash
bundle exec rake coverage
```

Coverage is opt-in so the default run stays dependency light. The suite holds
100% line coverage; the only branches it does not reach are the
`require ... unless defined?` guards at the top of the driver, which cannot take
both paths in a single process. Coverage is reported, not enforced in CI — treat
a drop as a prompt to look, not as a target to game.

## Documentation

Every method, constant and module carries YARD tags, and `yard stats` reports
100% documented. If you add a method, document it:

```ruby
# Looks an Instance up by ID, treating "not found" as a normal outcome.
#
# @param server_id [String] ID of the Instance to fetch
# @return [Hash, nil] the Server object, or nil if it no longer exists
# @raise [Kitchen::ActionFailed] for any API error other than a 404
def find_server(server_id)
```

Documentation is deliberately **not** a CI gate — a missing tag should never turn
a pull request red. Check it locally instead:

```bash
bundle exec rake yard:stats
```

YARD lives in the `development` bundler group, which CI excludes. If it is not
installed, `rake yard` explains how to get it and the rest of the tasks carry on
working.

## Adding a platform image label

`PLATFORM_IMAGE_LABELS` in `lib/kitchen/driver/scaleway.rb` maps short platform
names onto Scaleway marketplace image labels. Add the entry there and add the
matching row to the table in the README — `spec/readme_spec.rb` fails if the two
disagree, so this cannot drift silently. Adding a mapping is a `feat:` change.

Nothing needs to be added for a label to work at all: an unmapped platform name is
passed to the API untouched.

## Style

```bash
bundle exec rake style
```

CI runs `cookstyle --chefstyle`. `spec/` is excluded from style checks, so
expressive test code is fine.

## Commit messages and releases

Releases are automated with
[release-please](https://github.com/googleapis/release-please), which builds the
changelog and picks the next version from commit messages. Use
[Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Use it for | Version bump |
| --- | --- | --- |
| `fix:` | A bug fix | patch |
| `feat:` | A new setting or capability | minor |
| `docs:` | Documentation only | none |
| `test:` | Tests only | none |
| `chore:`, `ci:` | Tooling and CI | none |

A breaking change gets a `!` after the prefix (`feat!:`) or a
`BREAKING CHANGE:` footer, and bumps the major version.

Do not edit `CHANGELOG.md` or bump `SCALEWAY_VERSION` by hand. release-please
owns both.

## Opening a pull request

1. Fork the repository.
1. Create a feature branch (`git checkout -b my-new-feature`).
1. Make your change, with tests.
1. Check it with `bundle exec rake`.
1. Push the branch and open a pull request.

Describe what changed and why. If you fixed a bug, a test that fails without your
change is the most useful thing you can include.
