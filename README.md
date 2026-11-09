# GCP Internet Data Transfer Out (DTO) and Cloud NAT cost from the billing export

These queries use only the Cloud Billing export to BigQuery. Flow logs are not needed.

## Avoiding double counting
Traffic that leaves through Cloud NAT is billed **once**, as internet egress, to the **VM that sent it**. Cloud NAT also bills two charges of its own:
- `Data Processing`, for **the same bytes** in **both directions** (outbound and inbound).
- `Gateway Uptime`, in hours.

| Category | SKUs | Sum the GiB? | Sum the cost? |
|---|---|---|---|
| `INTERNET_DTO` | `Network Internet Egress / Data Transfer Out from <src> to <dest>` (Premium and Standard tier) | **Yes**: this is DTO | Yes |
| `NAT_PROCESSING` | `Cloud NAT Data Processing`, `Cloud NAT Gateway Uptime` | **No**: it repeats DTO bytes and includes inbound traffic | Yes: it is a separate charge |

**Costs add up. GiB do not.**
- DTO volume = `dto_gib` only.
- Total spend = DTO cost + NAT cost.

---

## 1. Common requirements (all queries)

### 1.1 Billing export
- Turn on Cloud Billing export to BigQuery under **Billing → Billing export → BigQuery export**.
- **Detailed usage cost** (`gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID>`) is recommended. Query 04 needs it, as does the per-gateway column in query 05.
- The **standard** export (`gcp_billing_export_v1_*`) works for queries 01, 02, 03, 06 and 07. For query 05, remove the `resource.name` column first.
- The export is not backfilled. Data starts from the day the export was turned on. Later rows can still arrive or be adjusted for a few days, which is why every query reads ±5 days of `_PARTITIONTIME` around the usage window.

### 1.2 Working dataset `${DS}`
- This is a dataset you own, where `dto_sku_map` gets created.
- It **must be in the same location** (for example `US` or `EU`) as the billing export dataset. BigQuery cannot join across locations.

```bash
bq mk --location=US --dataset myproj:finops
```

### 1.3 IAM
| Role | Where | Needed for |
|---|---|---|
| `roles/bigquery.jobUser` | The project that runs the queries | All queries |
| `roles/bigquery.dataViewer` | The billing export dataset | All queries |
| `roles/bigquery.dataEditor` | `${DS}` | 02 (creates the table), plus reading it in 03–07 |

### 1.4 Tools
- The `bq` CLI, from the Google Cloud SDK, logged in with `gcloud auth login`.
- `envsubst` for the placeholders. On macOS, install it with `brew install gettext`.
- Alternatively, paste each query into the BigQuery console and swap in the values by hand.

### 1.5 Placeholders
| Placeholder | Example | Meaning |
|---|---|---|
| `${BILLING_TABLE}` | `myproj.billing.gcp_billing_export_resource_v1_01ABCD_23EFGH_45IJKL` | Fully qualified billing export table |
| `${DS}` | `myproj.finops` | Working dataset (`project.dataset`) |
| `${START}` | `2026-10-01` | Start of the usage window, inclusive |
| `${END}` | `2026-11-01` | End of the usage window, **exclusive** |

```bash
export BILLING_TABLE=myproj.billing.gcp_billing_export_resource_v1_01ABCD_23EFGH_45IJKL
export DS=myproj.finops
export START=2026-10-01
export END=2026-11-01

# Helper: substitute only our variables (leaves regex `$` untouched) and run.
run() { envsubst '$BILLING_TABLE $DS $START $END' < "$1" | bq query --use_legacy_sql=false --max_rows=10000 --format=pretty; }
```
To get CSV output, use `--format=csv > out.csv` in place of `--format=pretty`.

### 1.6 Dependency order
```
01 (look) ──► 02 (create + review map) ──► 03, 04, 05, 06 (reports) ──► 07 (checks)
```
- **Run 02 once and keep it.** Run it again only when 07a reports SKUs it doesn't know.
- 03–07 can be run again for any period.

---

## 2. Per-query reference

### 01_sku_discovery.sql: find the relevant SKUs
| | |
|---|---|
| **Purpose** | List every egress, data transfer and NAT SKU that actually appears in your bill. SKU names differ across accounts and have changed over time ("Egress" became "Data Transfer"). |
| **Requires** | `${BILLING_TABLE}`, `${START}`, `${END}`. Read access only. |
| **Depends on** | Nothing |
| **Writes** | Nothing |

**Run**
```bash
run sql/01_sku_discovery.sql
```

**Result:** one row per SKU, sorted by cost with the highest first.

| Column | Meaning |
|---|---|
| `service` | For example `Compute Engine`, `Networking`, `Cloud Storage` |
| `sku_id` | Stable SKU identifier, used as the key in 02 |
| `sku` | SKU description, for example `Network Internet Data Transfer Out from Virginia to Americas` |
| `pricing_unit` | `gibibyte` for data transfer, `hour` for NAT uptime |
| `qty` | Quantity in `pricing_unit` |
| `cost` | Gross cost, before credits |

**What to do with it:** read through the list and get a feel for which SKUs are internet DTO, which are NAT, and which are internal or hybrid traffic.

---

### 02_sku_map.sql: build the SKU → category map
| | |
|---|---|
| **Purpose** | Put each SKU in **exactly one** category. This table is what prevents double counting. |
| **Requires** | `${BILLING_TABLE}`, `${DS}`. Write access to `${DS}`. It scans the **last 90 days**, not `${START}`/`${END}`. |
| **Depends on** | 01, for your review |
| **Writes** | `${DS}.dto_sku_map`. Running it again **replaces** the table, including any manual fixes, so save your fixes as `UPDATE` statements. |

**Run**
```bash
run sql/02_sku_map.sql

# Review
bq query --use_legacy_sql=false --format=pretty \
  "SELECT category, sku_id, sku, service FROM \`${DS}.dto_sku_map\` ORDER BY category, sku"

# Fix any wrong or REVIEW rows
bq query --use_legacy_sql=false \
  "UPDATE \`${DS}.dto_sku_map\` SET category='INTERNET_DTO' WHERE sku_id='XXXX-XXXX-XXXX'"
```

**Result:** the table `dto_sku_map(sku_id, sku, service, category)`.

| Category | Counted as |
|---|---|
| `INTERNET_DTO` | **DTO** |
| `INTERNET_DTO_CDN` | CDN cache egress. Kept out of DTO by default |
| `NAT_PROCESSING` | **NAT cost** (processing GiB and uptime hours) |
| `GCP_INTERNAL` | Inter-region and inter-zone traffic. Not DTO |
| `HYBRID` | Interconnect, VPN and peering. Not DTO |
| `GOOGLE_SERVICES` | Egress to Google services. Not DTO |
| `REVIEW` | Not classified yet. **Must be zero before you report** |

**What done looks like:**
- No `REVIEW` rows remain.
- Every `Internet ... Egress/Data Transfer Out` SKU is `INTERNET_DTO`.
- Every `Cloud NAT` SKU is `NAT_PROCESSING`.

---

### 03_dto_by_region.sql: DTO by region and destination
| | |
|---|---|
| **Purpose** | The main DTO number: GiB and cost by month, source region and destination area. |
| **Requires** | `${BILLING_TABLE}`, `${DS}`, `${START}`, `${END}` |
| **Depends on** | 02 |
| **Writes** | Nothing |

**Run**
```bash
run sql/03_dto_by_region.sql
```

**Result**
| Column | Meaning |
|---|---|
| `month` | `YYYY-MM` of `usage_start_time` |
| `src_region` | GCP region the traffic left from. `global/unknown` when billing gives no region |
| `dest_geo` | Destination area taken from the SKU name, for example `Americas`, `EMEA`, `APAC`, `China`, `Australia`, `Worldwide` |
| `category` | `INTERNET_DTO` or `INTERNET_DTO_CDN` |
| `pricing_unit` | Should be `gibibyte` |
| `gib` | **DTO volume in GiB** |
| `gross_cost` | Cost before credits |
| `net_cost` | Cost after credits (CUDs, promotions, free tier and so on) |

Illustrative example:
```
month    src_region   dest_geo  category      gib       gross_cost  net_cost
2026-10  us-east4     Americas  INTERNET_DTO  18,240.5  1,641.65    1,641.65
2026-10  europe-west1 EMEA      INTERNET_DTO   6,102.0    549.18      530.10
```
**Totals:** `SUM(gib)` is the period's internet DTO, and it already includes traffic that went through Cloud NAT.

---

### 04_dto_by_resource.sql: DTO by project and resource
| | |
|---|---|
| **Purpose** | See which VMs, load balancers or buckets produce the DTO. VMs behind Cloud NAT appear under **their own** name. |
| **Requires** | The **detailed** billing export, plus `${BILLING_TABLE}`, `${DS}`, `${START}`, `${END}` |
| **Depends on** | 02 |
| **Writes** | Nothing |

**Run**
```bash
run sql/04_dto_by_resource.sql
```

**Result**
| Column | Meaning |
|---|---|
| `month`, `project_id`, `src_region`, `service` | Grouping keys |
| `resource_name` | Short resource name, for example a VM name |
| `resource_global_name` | Full resource path, for example `//compute.googleapis.com/projects/.../instances/...` |
| `labels` | Resource labels as JSON, useful for charging back to teams or apps |
| `gib`, `gross_cost`, `net_cost` | DTO volume and cost |

**Checks**
- `SUM(gib)` here equals `SUM(gib)` from 03 for the same period.
- A row with an empty `resource_name` is usage that billing did not tie to any resource.

---

### 05_nat_processing.sql: Cloud NAT charges
| | |
|---|---|
| **Purpose** | Cloud NAT processing and uptime cost per gateway. Reported **separately** from DTO. |
| **Requires** | `${BILLING_TABLE}`, `${DS}`, `${START}`, `${END}`. Use the detailed export to fill `nat_resource`. |
| **Depends on** | 02 |
| **Writes** | Nothing |

**Run**
```bash
run sql/05_nat_processing.sql
```

**Result**
| Column | Meaning |
|---|---|
| `month`, `project_id`, `region` | Grouping keys |
| `nat_resource` | NAT gateway or router resource. Detailed export only |
| `sku` | `Cloud NAT Data Processing` or `Cloud NAT Gateway Uptime` |
| `pricing_unit` | `gibibyte` for processing, `hour` for uptime |
| `qty` | GiB processed (outbound **and** inbound) or gateway hours |
| `gross_cost`, `net_cost` | NAT cost |

**How to read it:** the processed GiB **is not extra egress**. Never add it to `gib` from 03 or 04.

---

### 06_dto_and_nat_summary.sql: main report (DTO + NAT)
| | |
|---|---|
| **Purpose** | One row per month, project and region, with DTO and NAT side by side and a combined cost. |
| **Requires** | `${BILLING_TABLE}`, `${DS}`, `${START}`, `${END}` |
| **Depends on** | 02 |
| **Writes** | Nothing |

To save the output as a table for dashboards (Looker Studio and so on):
```bash
envsubst '$BILLING_TABLE $DS $START $END' < sql/06_dto_and_nat_summary.sql \
  | bq query --use_legacy_sql=false --destination_table="${DS/./:}.dto_nat_summary" --replace
```

**Run**
```bash
run sql/06_dto_and_nat_summary.sql
```

**Result**
| Column | Meaning | Sum it? |
|---|---|---|
| `month`, `project_id`, `region` | Grouping keys | |
| `dto_gib` | Internet DTO volume, NAT traffic included | **Yes**: this is DTO volume |
| `dto_gross_cost`, `dto_net_cost` | DTO cost | Yes |
| `nat_processed_gib` | GiB processed by NAT, both directions | **No**: shown for information only |
| `nat_processing_cost` | NAT processing cost, gross | Yes |
| `nat_gateway_hours` | NAT gateway uptime hours | No |
| `nat_uptime_cost` | NAT uptime cost, gross | Yes |
| `nat_net_cost` | All NAT cost after credits | Yes |
| `total_net_cost` | `dto_net_cost + nat_net_cost` | Yes: total spend |

Illustrative example:
```
month    project_id  region    dto_gib   dto_net_cost  nat_processed_gib  nat_processing_cost  nat_gateway_hours  nat_uptime_cost  nat_net_cost  total_net_cost
2026-10  app-prod    us-east4  18,240.5  1,641.65      21,900.3           985.51               744                 32.74           1,018.25      2,659.90
```
Here `nat_processed_gib` is larger than `dto_gib`. This is expected, because NAT also counts inbound responses. **The DTO is still 18,240.5 GiB, not 40,140.8.**

---

### 07_checks.sql: integrity checks
| | |
|---|---|
| **Purpose** | Confirm the SKU map is complete and has no duplicates, and that the totals match the bill. |
| **Requires** | `${BILLING_TABLE}`, `${DS}`, `${START}`, `${END}` |
| **Depends on** | 02, and run after 03–06 |
| **Writes** | Nothing |

**Run:** the file holds four statements. Choose one of these:
- Run it in the **BigQuery console**, which shows each statement's results in its own tab.
- Run it with `bq` as a script, then open the BigQuery console job history to see the results of each child job.

```bash
run sql/07_checks.sql
```

**Results and what they should show**
| Check | Output | Pass when | If it fails |
|---|---|---|---|
| **7a** Unmapped SKUs | Egress, data transfer or NAT SKUs in the period that are missing from `dto_sku_map` | **0 rows** | Run 02 again (it scans 90 days), or add the SKUs by hand. DTO or NAT is understated until you do |
| **7b** Duplicate SKU rows | `sku_id` values that appear in more than one row | **0 rows** | Remove the duplicates. Each extra row repeats that SKU's cost in the joins |
| **7c** `REVIEW` rows | SKUs that are still unclassified | **0 rows** | Classify them with `UPDATE` |
| **7d** Totals by category | `qty` and `gross_cost` for `INTERNET_DTO`, `INTERNET_DTO_CDN` and `NAT_PROCESSING` | `gross_cost` matches the **Billing → Reports** console for the same SKUs, period and projects | Check the date window (the console uses invoice time, the queries use usage time) and the SKU filters |

---

## 3. Run everything with `run_all.sh`
The script runs 01 → 02 → 03–06 → 07 in order. Each result is saved as CSV, and the script prints a preview of each one.

**Requirements:** the same as section 1, meaning `bq`, `envsubst`, the IAM roles, and the 4 environment variables. The script checks all of these before running anything.

```bash
export BILLING_TABLE=myproj.billing.gcp_billing_export_resource_v1_01ABCD_23EFGH_45IJKL
export DS=myproj.finops
export START=2026-10-01 END=2026-11-01

./run_all.sh --dry-run          # estimate bytes scanned, run nothing
./run_all.sh                    # first run: builds dto_sku_map, then reports + checks
./run_all.sh --skip-discovery --strict --save-summary   # monthly run
```

| Option | Effect |
|---|---|
| `--rebuild-map` | Runs 02 even when `dto_sku_map` already exists. **This replaces the table, so manual fixes are lost** |
| `--skip-discovery` | Skips 01 |
| `--save-summary` | Also writes the 06 output to `${DS}.dto_nat_summary`, replacing it each run |
| `--strict` | Exits with code `2` if 7a, 7b or 7c returns any rows. Use it in automation |
| `--dry-run` | Only runs `bq --dry_run` on each query and prints the bytes it would scan |
| `--out DIR` | Output folder. Default: `out/<START>_<END>_<timestamp>/` |

**Behaviour**
- **02 runs only when `${DS}.dto_sku_map` doesn't exist yet**, or when you pass `--rebuild-map`. After building a new map, the script writes it to `02_sku_map_contents.csv` and warns you to review it.
  - On the first run, review the map, fix it with `UPDATE` statements, then run the script again.
- **07 is split into its four statements**, so each check gets its own CSV and a PASS or WARN line.
- **Dry run on the first run:** the reports and checks will fail if `dto_sku_map` doesn't exist yet, because the dry run doesn't create it. Run 02 once for real first.

**Output folder**
```
out/2026-10-01_2026-11-01_20261109-101500/
  01_sku_discovery.csv          06_dto_and_nat_summary.csv   <- main report
  02_sku_map_contents.csv       07a_unmapped_skus.csv        <- must be empty
  03_dto_by_region.csv          07b_duplicate_skus.csv       <- must be empty
  04_dto_by_resource.csv        07c_review_rows.csv          <- must be empty
  05_nat_processing.csv         07d_totals_by_category.csv   <- compare to Billing console
  *.sql                          (the exact SQL that ran, with placeholders filled in)
```

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | Success. Checks may still have warned if `--strict` was not set |
| `1` | A preflight check or a query failed |
| `2` | `--strict` was set and a check failed |

## 4. Recommended monthly runbook (manual)
```bash
export START=2026-10-01 END=2026-11-01
run sql/07_checks.sql                 # 7a/7b/7c must be empty (view in console)
run sql/06_dto_and_nat_summary.sql    # main report
run sql/03_dto_by_region.sql          # breakdown by region and destination
run sql/04_dto_by_resource.sql        # top resources (detailed export)
run sql/05_nat_processing.sql         # NAT per gateway
```

## 5. Running the queries manually in the BigQuery console
Use this when you don't have the `bq` CLI, or when you want to look at each result yourself.

### 5.1 One-time setup
1. **Open the console** at <https://console.cloud.google.com/bigquery>. Choose the project that runs the queries from the project picker at the top. You need `roles/bigquery.jobUser` on that project.
2. **Find the billing export table.**
   - In the **Explorer** pane, expand the project that holds the billing export, then its billing dataset.
   - Find the table `gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID>`.
   - Click **⋮ → Copy ID**. This gives you `project.dataset.table`, which is your `${BILLING_TABLE}`.
   - Can't find it? Go to **Billing → Billing export → BigQuery export** to see which project and dataset it uses.
3. **Note the billing dataset's location.** Click the billing dataset and open the **Details** tab. Note the **Data location**, for example `US`.
4. **Create the working dataset `${DS}`.**
   - In Explorer, click **⋮** next to your project and choose **Create dataset**.
   - Dataset ID: for example `finops`.
   - **Location type / Region: the same as the billing dataset.** If the locations differ, the queries fail with `Not found: Dataset ... was not found in location ...`.
   - Click **Create dataset**. `${DS}` is now `yourproject.finops`.

### 5.2 Fill in the placeholders
The console has no variable substitution, so `${BILLING_TABLE}`, `${DS}`, `${START}` and `${END}` must be replaced before you run anything. Choose one way:

- **Option A: generate ready-to-paste files locally.** This is the recommended way.
  ```bash
  export BILLING_TABLE=myproj.billing.gcp_billing_export_resource_v1_01ABCD_23EFGH_45IJKL
  export DS=myproj.finops START=2026-10-01 END=2026-11-01
  mkdir -p rendered
  for f in sql/*.sql; do envsubst '$BILLING_TABLE $DS $START $END' < "$f" > "rendered/$(basename "$f")"; done
  # or copy one straight to the clipboard (macOS):
  envsubst '$BILLING_TABLE $DS $START $END' < sql/06_dto_and_nat_summary.sql | pbcopy
  ```
  Then open each file in `rendered/` and paste it into the console.
- **Option B: find and replace in the console editor.**
  - Paste the SQL from `sql/` into the editor.
  - Open replace with **Ctrl+H** on Windows or Linux, or **Cmd+Option+F** on macOS.
  - Replace each placeholder, **including the `${` and `}`**:

    | Find | Replace with (example) |
    |---|---|
    | `${BILLING_TABLE}` | `myproj.billing.gcp_billing_export_resource_v1_01ABCD_23EFGH_45IJKL` |
    | `${DS}` | `myproj.finops` |
    | `${START}` | `2026-10-01` |
    | `${END}` | `2026-11-01` (exclusive) |

  - Keep the surrounding backticks and quotes as they are. For example, `` `${DS}.dto_sku_map` `` becomes `` `myproj.finops.dto_sku_map` ``, and `DATE '${START}'` becomes `DATE '2026-10-01'`.

### 5.3 Running a query
1. Click **+ Compose new query**, or **+** for a new tab, and paste the SQL with the placeholders filled in.
2. **Check the estimate before you run.** The editor validates the query and shows *"This query will process X GB when run"* at the top right.
   - A red error at this point usually means a placeholder wasn't replaced, or a table or location is wrong.
   - The estimate for 02 and 07 can be lower than the real figure, because they are scripts.
3. *(Optional)* Under **More → Query settings**, leave **Data location** on *Automatic*, or set it to the billing dataset's location.
4. Click **Run**.
5. **Read the results** in the **Results** tab at the bottom.
   - **Scripts with more than one statement** (07, and 02 if you add UPDATEs to it) show a list of statements. Click **View results** on each one to see its output.
6. **Save the output** with **Save results**, which offers:
   - **CSV (local file):** small result sets only, about 10 MB at most.
   - **CSV (Google Drive)** or **Google Sheets:** for larger results.
   - **BigQuery table:** for example, save 06 as `finops.dto_nat_summary` for dashboards.
   - Alternatively, use **Explore data → Explore with Looker Studio**.
7. *(Optional)* Click **Save → Save query** to keep a named copy for next month. You'll only need to change the dates.

### 5.4 Run order in the console
| Step | Paste and run | What to do with the result |
|---|---|---|
| 1 | `01_sku_discovery.sql` | Look over the egress, data transfer and NAT SKUs and how much each costs |
| 2 | `02_sku_map.sql` | Creates `finops.dto_sku_map`. **Only on the first run, or when 7a reports new SKUs** |
| 3 | `` SELECT category, sku_id, sku, service FROM `myproj.finops.dto_sku_map` ORDER BY category, sku; `` | Review every row |
| 4 | `` UPDATE `myproj.finops.dto_sku_map` SET category = 'INTERNET_DTO' WHERE sku_id = 'XXXX-XXXX-XXXX'; `` | Fix wrong or `REVIEW` rows. Keep these statements in a saved query so you can re-apply them if 02 is ever run again |
| 5 | `07_checks.sql` | Statements 7a, 7b and 7c must return **no rows**. Fix the map until they do |
| 6 | `03_dto_by_region.sql` | DTO by region and destination |
| 7 | `04_dto_by_resource.sql` | DTO by VM or resource. Needs the detailed export |
| 8 | `05_nat_processing.sql` | NAT cost per gateway |
| 9 | `06_dto_and_nat_summary.sql` | **The main report.** Save results as a table or sheet |
| 10 | `07_checks.sql`, statement 7d | Compare `gross_cost` with **Billing → Reports**, filtered to the same SKUs, projects and dates |

### 5.5 Common console errors
| Error | Cause | Fix |
|---|---|---|
| `Syntax error: Unexpected "$"` | A placeholder wasn't replaced | Replace every `${...}` (see 5.2) |
| `Not found: Table ...dto_sku_map` | 02 hasn't been run yet, or `${DS}` is wrong | Run 02, or check the dataset name |
| `Not found: Dataset ... was not found in location XX` | `${DS}` and the billing dataset are in different locations | Create `${DS}` again in the billing dataset's location |
| `Access Denied: ... bigquery.jobs.create` | You lack `jobUser` on the selected project | Switch projects, or ask for `roles/bigquery.jobUser` |
| `Access Denied: Table ...gcp_billing_export...` | You lack `dataViewer` on the billing dataset | Ask for `roles/bigquery.dataViewer` on that dataset |
| `Unrecognized name: resource` | You are using the **standard** export | Use the detailed export for 04, or remove `resource.*` from 04 and 05 |
| The results are empty | The window is outside the export's history, or `${END}` was set equal to `${START}` | Check the dates. The export has no data from before it was turned on |

## 6. Out of scope for DTO
- Inter-region, inter-zone and Interconnect/VPN egress, plus traffic to Google services. These are categorised in the map but not counted.
- CDN cache egress (`INTERNET_DTO_CDN`) is kept out by default. Add it to the `IN (...)` filter in 03 and 06 if your definition of DTO includes CDN.

## 7. Cost of running these queries
- Every query prunes on `_PARTITIONTIME`, so the bytes scanned grow with the window plus 10 days.
- Check the cost before running with `bq query --dry_run`.
