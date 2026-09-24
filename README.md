# GridPing — Backend

Julia services that simulate smart-meter power flow on local hardware, write readings to PostgreSQL (AWS RDS), and expose the same data to the dashboard via a read-only Lambda API.

Most domestic smart meters have very limited computing power and thus lack the ability to perform detailed power grid analysis. The project team are working together, under the guidance of Dr. Eduardo Cotilla-Sanchez, to develop a GPU-accelerated smart meter alongside grid algorithms to allow for real-time analysis of large power grid cases. This repo is the **cloud + simulation backend** in that pipeline.

## Related repos & site

| Piece | Link |
|-------|------|
| Smart meter dashboard (React) | [rojaslesly/smartMeter](https://github.com/rojaslesly/smartMeter) |
| Landing & pipeline showcase | [nikoloda/GridPing-Showcase](https://github.com/nikoloda/GridPing-Showcase) · [gridping.vercel.app](https://gridping.vercel.app/) |
| Backend (this repo) | Simulation, RDS writes, Lambda read API |

## What it does

- **Meter poller** — loads MATPOWER cases, runs AC power flow (PowerModels + Ipopt), computes local/global PQ and island count, inserts into `records` / `globalRecords`
- **Case tooling** — generate perturbed hourly cases; audit generated and event cases for convergence
- **DB helpers** — peek or clear SQLite (local) or Postgres (AWS)
- **Lambda** — SQL queries for the dashboard (`latest_bus`, `bus_24h`, `latest_global`, `last_outage`); does not run power flow

Simulation runs on **your machine** (or edge device). **RDS** stores rows. **EC2** is only an SSH jump host for dev writes. **Lambda** reads RDS for the React app.

## Tech stack

| Layer | Technology |
|-------|------------|
| Simulation | Julia, PowerModels, Ipopt, JuMP |
| AWS DB | RDS (PostgreSQL), LibPQ |
| Local DB | SQLite (optional) |
| API | Node.js Lambda (`pg`) |
| Cases | MATPOWER `.m` under `cases/transmission/` |

## Getting started

### 1. Julia environment

Install Julia and project deps (PowerModels, Ipopt, LibPQ, etc.) as used in `scripts/` and `src/`.

### 2. Environment file

Contact **nikoloda@oregonstate.edu** for credentials. Place `.env` at the repo root (gitignored):

```env
PGHOST=localhost
PGPORT=5433
PGUSER=______________
PGDATABASE=______________
PGPASSWORD=______________
```

Or a single `PG_CONN=...` string. `connect_pg()` in `src/DB_AWS_PostgreSQL.jl` loads unset vars from `.env`.

### 3. AWS tunnel (writes from your laptop)

RDS is not public. Open a tunnel through the bastion EC2 (region **us-west-2**). Get **bastion public IP** and **RDS endpoint** from the AWS console (EC2 → Instances; RDS → Databases). If SSH times out, start the EC2 instance and allow **SSH (22)** from your IP on its security group.

Leave this terminal open:

```bash
ssh -i /path/to/bastion-key.pem -L 5433:<rds-endpoint>:5432 ec2-user@<bastion-ip> -N
```

Verify:

```bash
julia db_manual/peek_postgres.jl
```

Lambda in production uses `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` and talks to RDS directly—no tunnel.

### 4. Run the meter poller

```bash
julia scripts/meter_reading_simulator.jl
```

Defaults: bus `6`, 24 hourly steps, 45 s between readings, Postgres on (`USE_AWS_POSTGRES`). Toggle SQLite or timing flags at the top of the script.

Optional long-running variant: `julia scripts/meter_reading_simulator_forever.jl`.

### 5. Other scripts

```bash
julia scripts/check_generated_case_solvability.jl
julia scripts/matpower_case_generator.jl    # see script for args / output dir
julia db_manual/clear_postgres_records.jl     # destructive — truncates AWS tables
```

`notebooks/` — early experiments and prototypes (e.g. Postgres init, population); kept as artifacts, not required for the poller flow.

## Lambda API (frontend contract)

Implemented in `lambda/index.mjs`. Matches table layout from `DB_AWS_PostgreSQL.jl`. Query param `query`:

| Query | Parameters | Returns |
|-------|------------|---------|
| `latest_bus` | `bus_id`, `target_time` | Closest meter record for bus |
| `bus_24h` | `bus_id`, `target_time` | Bus records in prior 24 h |
| `latest_global` | `target_time` | Closest global grid record |
| `last_outage` | `bus_id`, `target_time` | Latest outage row for bus |

`target_time`: `YYYY-MM-DD HH:mm:ss`. Response shape: `{ query, target_time, count, rows[] }`.

## Project structure

```
cases/transmission/ # MATPOWER .m — base, generated_cases/, event_cases/
db_manual/          # peek / clear SQLite or Postgres
lambda/             # Read API for dashboard
notebooks/          # Experimentation / idea testing (historical artifacts)
scripts/            # Poller, case generator, solvability audit
src/                # DB_AWS_PostgreSQL.jl, DB_SQLite.jl
```

**OpenDSS (`.dss`) cases:** use [dss-extensions/electricdss-tst](https://github.com/dss-extensions/electricdss-tst) for IEEE/EPRI examples and other test circuits (filtered OpenDSS sample scripts).

## Contact

Daniel Nikolov — nikoloda@oregonstate.edu
