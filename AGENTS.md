# UTA (Universal Transcript Archive)

Code that *generates* the UTA PostgreSQL database: RefSeq transcripts aligned to reference genomes, consumed by [hgvs](https://github.com/biocommons/hgvs) for coordinate mapping. Releases are dated schemas (`uta_YYYYMMDD`) shipped as Docker images (`biocommons/uta:<tag>`) and `.pgd.gz` dumps on dl.biocommons.org. The README is the user-facing runbook (install, update procedure, migrations); this file is the map behind it.

## Layout

| Path | Role |
|---|---|
| `src/uta/models.py` | SQLAlchemy schema. `schema_version` (currently `1.2`) and `schema_name = "uta"` live here. |
| `src/uta/loading.py` | Every `uta <subcommand>` implementation: `create_schema`, `load_*`, `align_exons`, `refresh_matviews`, `grant_permissions`, ... |
| `src/uta/cli.py` | docopt dispatcher. `uta -C etc/global.conf -C etc/uta_dev@localhost.conf <cmd>`; later `-C` files override earlier. |
| `src/uta/formats/` | Readers/writers for the intermediate TSVs (`txinfo`, `exonset`, `seqinfo`, `geneinfo`, `geneaccessions`). Header must match `_fields` exactly or the reader raises. |
| `src/uta/parsers/seqrecord.py` | `SeqRecordFacade`: pulls gene id, CDS, exons, `codon_table`, `transl_except` out of a Biopython GenBank record. Used by `sbin/ncbi-parse-gbff` and mito processing. |
| `src/alembic/versions/` | Schema migrations, scoped to the `uta` schema only (`env.py` `include_name`). Views and matviews are now created in migrations, not `sql/`. |
| `sbin/` | Pipeline stages, each a standalone script (bash or Python). Python ones are importable as `sbin.<name>` from the repo root (tests do this). |
| `etc/` | `global.conf` + `uta_dev@localhost.conf` (db url, `admin_role`, SeqRepo path), `alembic.ini`, `ncbi-files.txt` (rsync paths), `scripts/{create-new,delete}-schema.sh`. |
| `docker-compose.yml` | Services for the update procedure. One-off workflows have their own overlays under `misc/` (see Gotchas). |
| `misc/` | One-time workflows and research scratch. Live: `mito-transcripts/`, `splign-manual/`, `refseq-historical-backfill/`, `gene-update/`, `docker/` (publishing the release image). The rest is historical. |
| `loading/data/` | Checked-in manual inputs, chiefly `splign-manual/` (txdata.yaml + `.splign` alignments, with a README on how they were made). |
| `tests/` | `unittest`; `tests/data/` fixtures. |

## Data flow

Stages, in the order `docker-compose.yml` / README run them. Each stage reads and writes `$UTA_ETL_WORK_DIR`:

1. `sbin/seqrepo-pull` — rsync the latest public SeqRepo and clone it into a writable `master` instance at `/biocommons/dl.biocommons.org/seqrepo/master` (a compose volume). All later sequence lookups go through this path (`etc/global.conf [sequences] seqrepo`).
2. `sbin/ncbi-download` — rsync paths listed in `etc/ncbi-files.txt` (gene_info, gene2refseq, `human.*.rna.gbff/fna`, `protein.faa`, and GRCh37/GRCh38/T2T `genomic.gff/fna`).
3. `sbin/uta-extract` — NCBI files → intermediates:
   - `ncbi-parse-geneinfo` → `geneinfo.gz`
   - `ncbi-parse-gene2refseq` → `assocacs.gz` (tx↔protein pairs)
   - `ncbi-parse-gbff` (NM_/NR_ only) → `txinfo.gz`
   - `ncbi-parse-gff` (cDNA_match records, with coverage/identity thresholds) → `cdna_match.exonsets.gz`
   - `ncbi_parse_genomic_gff.py` (exon features) → `exon_block.exonsets.gz`
   - `coalesce_exonsets.py cdna_match exon_block` → first file wins per `(tx_ac, alt_ac)`, so cDNA_match alignments take precedence (they encode NCBI's frameshift indels; exon blocks have micro-introns).
   - `filter_exonset_transcripts.py` → drops exonsets whose transcript isn't in `txinfo.gz` → `exonsets.gz`
   - copies all `*.fna.gz` / `*.faa.gz` into the work dir for the next step.
4. `sbin/seqrepo-load` — `seqrepo load -n NCBI` every fasta in the work dir.
5. `sbin/uta-load <old_v> <new_v> ...` — the actual DB build (see next section).

Mitochondrial transcripts (`sbin/ncbi_process_mito.py`, writes the same intermediate files from NC_012920.1 via eutils) and splign-manual alignments (`sbin/generate-loading-data`) are separate extract paths that feed the same `seqrepo-load` + `uta-load` tail.

## How `uta-load` builds a release

1. Drop schema `uta`; recreate it by `pg_dump`ing the *previous* release schema and piping through `sbin/pg-dump-schema-rename old_v uta` (`etc/scripts/create-new-schema.sh`). Every release is incremental on the previous one; there is no from-scratch build path in the live pipeline.
2. `alembic upgrade head`, then `uta update-meta-data` (bumps `meta.schema_version` to `models.schema_version`).
3. `exonset-to-seqinfo` (needs SeqRepo) and `assoc-acs-merge` (dedupes, keeps highest protein version).
4. Load in this order, which matters: `load-geneinfo` → `load-assoc-ac` → `load-txinfo` → `load-exonset` → `load-seqinfo` → `align-exons`. `load-exonset` looks up the transcript's own exon set (created by `load-txinfo`) and requires equal exon counts; `load-txinfo` requires an `origin` row named as in the file (`NCBI`) and fetches the CDS from SeqRepo to compute `cds_md5`.
5. `sbin/uta-diff old_v uta` prints per-table row counts unique/common between the two schemas; read it before trusting a build.
6. Rename `uta` → `<new_v>`, `pg_dump -n <new_v>` → `$UTA_ETL_WORK_DIR/<new_v>.pgd.gz`.

Loading semantics worth knowing before touching `loading.py`:

- `_upsert_exon_set_record` is idempotent. If an exon set for `(tx_ac, alt_ac, method)` exists with different exons, the old row's `alt_aln_method` is suffixed with `/<sha1[:8]>` and a new row is inserted. So `alt_aln_method` values like `splign/1a2b3c4d` are archived history, not a distinct aligner.
- If a transcript's CDS coordinates change, the old `transcript.ac` is renamed `NM_x.y/<start>..<end>` and a fresh row is inserted. `align_exons` skips `tx_ac ~ '/'`.
- Coordinates are 0-based half-open ("interbase"); the `_i` suffix means that. TSV columns `cds_se_i` are `start,end`, `exons_se_i` are `start,end;start,end;...`. GFF/GenBank 1-based positions are converted at parse time (`start - 1`), including `transl_except` positions.
- `exon_set.alt_aln_method = 'transcript'` is the transcript's exons on its own sequence; every other method is an alignment to a reference. `tx_alt_exon_pairs_v` pairs the two by `ord`.
- `load_seqinfo` stores sequences < 2 Mb inline in `seq.seq`; longer ones are NULL and must be fetched from SeqRepo.
- `refresh_matviews` hard-codes matview order (`exon_set_exons_fp_mv` → `tx_exon_set_summary_mv` → `tx_def_summary_mv` → `tx_exon_aln_mv`). `uta-load` does **not** call `refresh-matviews`, `grant-permissions`, or `analyze`; check whether a dump needs them before publishing.

## Schema and migrations

- One database, many schemas: `uta` is always the in-progress loading schema; releases are `uta_YYYYMMDD` schemas side by side. Alembic's version table lives inside `uta`, and `alembic.ini` hard-codes `postgresql://uta_admin:@localhost/uta`.
- Any change to `models.py` needs a migration (`alembic -c etc/alembic.ini revision --autogenerate`), and if the column shape changes, matching edits to the `formats/` record, the parser that fills it, and the loader. `a697b584f699_add_codon_table_to_transcript.py` is a clean example that also backfills data.
- Bumping `models.schema_version` is a deliberate act; `update-meta-data` propagates it into `meta`.
- `misc/gene-update/upgrade-uta-schema.sh` shows how a pre-alembic schema (`uta_20210129b`) was brought under alembic with `alembic stamp`.

## Test

CI (`.github/workflows/ci.yml`) runs:

```
docker build --target uta-test -t uta-test . && docker run --rm uta-test python -m unittest
```

Locally: `pip install -e .[test]`, then `python -m unittest` from the repo root. `tests/test_uta_loading.py` boots a throwaway Postgres with `testing.postgresql` and creates role `uta_admin`, so `initdb`/`postgres` must be on PATH. Every `sbin/*.py` script with logic has a `tests/test_<name>.py`; follow that pattern for new scripts.

## Conventions

- Python 3.10 or 3.11 in practice: `loading.py` uses `str | tuple` annotations (3.10+), while `cli.py` still calls `ConfigParser.readfp` and `pkg_resources` (gone in 3.12). The Docker image is 3.10. `pyproject.toml` says `>=3.9`; that is aspirational.
- ruff (`uv run --only-group dev ruff check .`; enforced in CI by `.github/workflows/ci.yml`): 120 columns, max complexity 10 (`[tool.ruff]` in `pyproject.toml`; tests, `archive/`, `misc/EnsemblUTA/` and `misc/bermuda/` excluded). Known complexity (C901) violations carry a line-level `# noqa`; don't add new ones. Code style is mixed-era; match the file you're in.
- Scripts configure logging via `importlib_resources.files("uta").joinpath("etc/logging.conf")` and write results to stdout, logs to stderr, so they compose with `| gzip -c > out.gz`.
- Commit messages and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/) (`type(scope): subject`, types `build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test`). CI (`.github/workflows/ci.yml`) checks every commit in a PR and the PR title with commitizen.
- Branch from `main`, PR back. Recent branches are `issue-<n>-<slug>`; Invitae-era commits carry `IPVC-####` Jira ids. CODEOWNERS is `@biocommons/maintainers`.
- The full update needs ~13 GB SeqRepo + multi-GB NCBI downloads and hours of load time. Develop against a restored release dump plus `tests/data` fixtures, not a fresh pipeline run.

## Gotchas (verified against the tree, 2026-10)

- README says `docker compose run splign-manual`, but that service is only defined in `misc/splign-manual/docker-compose-splign-manual.yml`. It needs `-f docker-compose.yml -f misc/splign-manual/docker-compose-splign-manual.yml`, like the mito step does.
- `Dockerfile` runs `pip install -e .[dev]`; there is no `dev` extra in `pyproject.toml` (only `test`). pip warns and continues.
- `uta.__init__.public_db_url` points at `uta.invitae.com`; the public host is `uta.biocommons.org` (README). Don't rely on the default `connect()`.
- `sql/` is not referenced by any live script; views now come from the previous dump plus alembic migrations. `sql/refresh-matviews.sql` lists different matviews than `loading.refresh_matviews`. Treat `sql/` as reference only.
- `pyproject.toml` still depends on `nose` and pins `setuptools_scm==1.11.1`; `__version__` is read via `pkg_resources`.
- Dead or legacy, don't build on: root `Makefile` (setup.py/nose/Mercurial), `loading/Makefile` + `loading/admin.mk` (pre-Docker load), `archive/`, `misc/EnsemblUTA/`, `misc/bermuda/`, `etc/uta_dev@uic.com`, `etc/ensembl.sh`, `.travis.yml`, `cli.py load-ncbi-seqgene` (half-finished).
- Release images for Docker Hub are built separately from `misc/docker/uta.dockerfile` and require the `.pgd.gz` to already be on dl.biocommons.org (`misc/docker/README.md`). The `uta_update.yml` workflow is a stub: it only echoes its inputs.
