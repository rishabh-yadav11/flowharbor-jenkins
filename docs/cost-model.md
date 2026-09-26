# Cost model

**Prices below are AWS public list prices, looked up on 2026-09-26 from the AWS Price List API** (`https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<service>/current/index.json`), not from a blog post, a calculator screenshot, or a third-party aggregator. Each row states the offer file and its publication date, so you can reproduce the number. Every quantity comes from the Terraform configuration as committed; where a quantity depends on traffic or on how much you actually push, the row says so instead of guessing.

**This is an estimate of list price, not a measurement.** No account exists for this repository and nothing here has been billed. The section [Measure it instead](#measure-it-instead) has the command that replaces this table with reality.

**Region:** `ap-south-1` (Mumbai) unless a row says otherwise. All prices in USD.

---

## Priced inventory

### Compute and networking (these run whether or not anyone uses the site)

| Resource | Qty | Unit | List price | Source (publication date) | Monthly |
| --- | --- | --- | --- | --- | --- |
| EC2 `t4g.medium` (Jenkins controller + agent), Linux | 2 | instance-hour | $0.0224 | AmazonEC2 `ap-south-1` (2026-09-25) | $32.70 |
| NAT gateways (one per AZ) | 2 | gateway-hour | $0.056 | AmazonEC2 `ap-south-1` (2026-09-25) | $81.76 |
| VPC interface endpoints (7 × 2 AZs) | 14 | endpoint-hour | $0.013 | AmazonVPC (2026-09-17) | $132.86 |
| Application Load Balancer | 1 | hour | $0.0053 | AWSELB (2026-09-11) | $3.87 |
| Fargate 0.25 vCPU / 0.5 GB — dev 1 + staging 2 + prod 2 | 5 | vCPU-hr + GB-hr | $0.04256 / $0.004655 | AmazonECS (2026-09-11) | $47.33 |
| EBS `gp3` root volumes (30 GB × 2) | 60 | GB-month | $0.0912 | AmazonEC2 `ap-south-1` (2026-09-25) | $5.47 |

### Observability, edge, and DNS

| Resource | Qty | Unit | List price | Source (publication date) | Monthly |
| --- | --- | --- | --- | --- | --- |
| WAFv2 web ACL (regional, on the ALB) | 1 | month | $5.00 | awswaf (2026-09-14) | $5.00 |
| WAFv2 rules on that ACL | 5 | month | $1.00 | awswaf (2026-09-14) | up to $5.00 |
| WAFv2 requests | traffic | million requests | $0.60 | awswaf (2026-09-14) | traffic-dependent |
| CloudWatch metric alarms | 7 | alarm-month | $0.10 | AmazonCloudWatch (2026-09-22) | $0.70 |
| Route 53 hosted zone | 1 | month | $0.50 | AmazonRoute53 (2026-09-11) | $0.50 |

### Rows I could not price from a source

These are real resources in this stack. I am not going to put a number next to them, because a number I cannot source is worse than an admission:

| Resource | Qty | Why there is no number |
| --- | --- | --- |
| CloudWatch Logs ingest and storage | 5 log groups (ECS dev/staging/prod, WAF, VPC flow logs) | I did not retrieve a verified ingest rate for this region |
| CloudWatch dashboard | 1 | Dashboard pricing is not region-scoped in the offer file; verify before assuming it is free |
| ECR image storage | grows with releases | Rate not retrieved; also depends on how many tags you keep |
| S3 (log bucket, Config bucket, state bucket) | small | Storage/request rates not retrieved |
| DynamoDB | `PAY_PER_REQUEST` | Rates are on-demand per request, and requests depend on real traffic |
| KMS CMKs (logs, DynamoDB, Route 53 DNSSEC, state) | 4 | No key-usage rate retrieved for this region |
| GuardDuty, AWS Config, Security Hub | enabled | No per-item rate retrieved for this region |
| Elastic IP addresses | 2 (one per NAT gateway) | Public-IPv4 billing rules are not in a file I retrieved; verify |
| ACM certificates | 2 | Typically free, but verify |
| CloudFront | `count = enable_cloudfront` | Disabled by default; see the delta section |
| SNS publishes | 1 per pipeline run | Negligible; included in nothing below |

---

## The arithmetic

Only the rows I can price, summed. Hours assume 730 per month.

```
EC2          2     × 730 h   × $0.0224  =  $32.70
NAT          2     × 730 h   × $0.056   =  $81.76
Endpoints    14    × 730 h   × $0.013   = $132.86
ALB          1     × 730 h   × $0.0053  =   $3.87
Fargate      5 tasks × (0.25 vCPU × 730 h × $0.04256
                        + 0.5 GB   × 730 h × $0.004655) = $47.33
gp3          60 GB × $0.0912                  =   $5.47
WAF ACL      1     × $5.00                    =   $5.00
WAF rules    5     × $1.00                    =  up to $5.00
Alarms       7     × $0.10                    =   $0.70
Route 53     1     × $0.50                    =   $0.50
                                         total ≈ $315 / month
```

Every line above is arithmetic on a sourced rate; none of it is a measurement. Treat $315 as a floor for an always-on stack, not a forecast.

**The budget agrees with this table.** `monthly_budget_usd` defaults to `400` (`terraform/variables.tf:162`) — above the $315 priced floor, so the 80% notification (i.e. $320) fires only when the stack has genuinely moved past its own arithmetic, not every month on a healthy account. The budget is COST-type with an ACTUAL 80% threshold and no subscriber until you configure one (`terraform/main.tf:125`), so set `budget_alert_emails` or lower the limit before the first deploy.

---

## The three largest levers

1. **VPC interface endpoints — $132.86/month, 42% of the priced total.** Seven interface endpoints (ECR API, ECR Docker, SSM, SSM messages, EC2 messages, ECR/logs, CloudWatch logs) each land in *both* private subnets, so the AZ count doubles the hourly charge. The endpoints exist to keep Fargate and the agent off the NAT path. If the stack is not running 24/7, the endpoints still are — they are billed by the hour regardless of whether a task is up.
2. **NAT gateways — $81.76/month, 26%.** One per AZ for AZ-failure isolation (`terraform/modules/vpc/main.tf:82`). Consolidating to one NAT halves this and reintroduces the single-AZ blackhole the per-AZ design was avoiding.
3. **Fargate — $47.33/month, 15%.** Five tasks at 0.25 vCPU / 0.5 GB, and staging and prod sit at two tasks each by default rather than scaling to zero. The autoscaling policies exist (`terraform/modules/ecs/autoscaling.tf:24`), so this is the "idle task" cost, not a scaling failure.

The two Jenkins hosts together ($32.70) are the smallest of the top four — the cost here is the always-on network plumbing, not the CI.

---

## What changes when `enable_cloudfront = true`

`enable_cloudfront` defaults to `false`, and the distribution is created with `count = var.enable_cloudfront` (`terraform/main.tf:345`). Flipping it to `true`:

- **Adds** a CloudFront distribution (its request and transfer rates are traffic-dependent), a CLOUDFRONT-scope WAF ACL in `us-east-1` ($5.00/month plus its three rules at $1.00 each, and a $0.60/million request charge), and a second hosted-zone record set.
- **Removes** nothing from the priced inventory above — the ALB, the endpoints, and the NAT gateways all stay, because CloudFront is in front of the ALB, not replacing it.
- **Makes required** the `cloudfront_origin_verify_token` variable, which must be at least 32 characters (`terraform/variables.tf:78`), and enables the origin-verify header condition on the prod listener rule.

So the honest answer: enabling CloudFront makes the stack **more** expensive, not less. Its value here is edge caching and the origin-bypass guard, not cost.

---

## Measure it instead

After the stack has been running for a full billing month, replace every estimate above with:

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -d 'first day of last month' +%F),End=$(date -d 'first day of this month' +%F) \
  --granularity MONTHLY \
  --metrics BlendedCost AmortizedCost UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region ap-south-1
```

For a per-resource breakdown, group by `LINKED_ACCOUNT` and `TAG` instead — the provider sets `Project`, `ManagedBy`, and `Repo` as `default_tags` on every resource (`terraform/main.tf:39`), so a cost report grouped by `Repo` attribute attributes the whole stack to one line.

The budget itself is the tripwire: point `budget_alert_emails` at a real address and it will tell you at 80% of the limit rather than at the end of the month (`terraform/main.tf:137`).
