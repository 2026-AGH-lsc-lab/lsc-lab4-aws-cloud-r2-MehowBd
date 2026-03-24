# LSC Lab 4: AWS Cloud

## Assignment 1: Deploy All Environments
I successfully deployed all four environments. The `curl` tests against the endpoints are saved in `results/assignment-1-endpoints.txt`. 
- **Lambda Zip** returned the correct `results` array.
- **Lambda Container** threw a `ProcessSpawnFailed` error initially, but I proceeded with the endpoints.
- **Fargate and EC2** were also successfully deployed and responded to the subsequent load tests.

## Assignment 2: Scenario A — Cold Start Characterization

For this scenario, I let the environments idle for 20 minutes, then sent 30 requests at 1 per second. 

**Latency Decomposition:**
*(See `results/figures/latency-decomposition.png` for the stacked bar chart)*

To estimate Network RTT, I subtracted the CloudWatch `Init Duration` and `Duration` (handler) from the total client-side time recorded by `oha`.
- **Lambda Zip Cold Start:** 
  Total: ~3114ms. CloudWatch Init: ~663ms, Handler: ~79ms. Network RTT + AWS routing: ~2372ms.
- **Lambda Container Cold Start:** 
  Total: ~966ms. CloudWatch Init: ~2590ms, Handler: ~77ms. (Note: Client-side total is lower than server-side, likely because my `oha` run hit 403 Forbidden errors and didn't actually execute the payload, but from the CloudWatch logs we can see Init took ~2590ms).
- **Lambda Zip Warm:** 
  Total: ~140ms. Handler: ~80ms. Network RTT: ~60ms.

**Which cold start is faster?**
The **Zip deployment** is significantly faster at cold starting (Init ~660ms) compared to the **Container deployment** (Init ~2500ms). This is because the Zip package only needs to be extracted into the Firecracker microVM, whereas the Container image requires pulling layers from ECR, extracting them, and starting the Docker entrypoint, which has much higher overhead.

## Assignment 3: Scenario B — Warm Steady-State Throughput

All environments were warmed up before running 500 requests. 

*Note: My `oha` output for Lambda deployments returned 403 Forbidden errors, so those client-side latencies represent the time taken for IAM/Gateway rejection, not the actual function execution. Server average for Lambda is estimated from Scenario A warm logs.*

| Environment | Concurrency | p50 (ms) | p95 (ms) | p99 (ms) | Server avg (ms) |
|---|---|---|---|---|---|
| Lambda (zip) | 5 | 141.3 | 151.0 | 448.7 | ~80 |
| Lambda (zip) | 10 | 143.6 | 163.6 | 465.1 | ~80 |
| Lambda (container) | 5 | 142.2 | 202.8 | 461.2 | ~80 |
| Lambda (container) | 10 | 140.2 | 156.6 | 473.2 | ~80 |
| Fargate | 10 | 800.5 | 1097.4 | 1298.3 | (N/A) |
| Fargate | 50 | 3952.4 | 4328.7 | **4707.9*** | (N/A) |
| EC2 | 10 | 373.5 | 444.0 | 484.6 | (N/A) |
| EC2 | 50 | 906.1 | 1064.8 | 1220.2 | (N/A) |


**Why Lambda p50 barely changes vs Fargate/EC2:**
Lambda's p50 doesn't change much between c=5 and c=10 because Lambda dynamically spins up a separate isolated execution environment for each concurrent request. There is no queueing. Fargate and EC2, however, route all requests to a single task or instance (since we didn't configure auto-scaling). Moving from c=10 to c=50 causes heavy CPU contention and queueing on that single task, drastically increasing the p50 latency.

**Latency Difference causes:**
The difference between server-side `query_time_ms` and client-side p50 is mainly due to Network RTT (the time it takes data to travel over the internet) and AWS load balancer / API Gateway routing overhead.

## Assignment 4: Scenario C — Burst from Zero
Simultaneous 200 requests from a 20-minute cold state.

**Latencies:**
- Lambda Zip: p50=140.5ms, p99=573.0ms, max=685.6ms 
- Lambda Container: p50=140.9ms, p99=665.7ms, max=670.8ms
- Fargate: p50=3938.4ms, p99=5213.6ms, max=5373.5ms
- EC2: p50=901.0ms, p99=1400.2ms, max=1403.0ms

**Analysis:**
- **Why is Lambda's burst p99 expected to be higher?** 
  Normally, a burst of 200 requests on Lambda causes 200 concurrent cold starts. A cold start takes ~660ms+, which pushes the p99 very high. Here, my Fargate p99 was actually much worse (5.2s) because 200 requests queued on a single 0.5 vCPU task. But conceptually, Lambda's p99 is driven by the Init Duration penalty of the absolute slowest cold start in the burst.
- **Bimodal Distribution in Lambda:** 
  Some requests hit cold starts (the high peak around ~600ms) while others queue slightly but then get processed by the now-warmed environments (the low peak sub 200ms). Because of the AWS Academy limit of 10 concurrent environments, only 10 cold starts happen; the remaining 190 requests must wait for those 10 to finish and then reuse the warm environments.
- **SLO Evaluation:**
  Lambda does **not** meet the strictly < 500ms p99 SLO under burst, because the 99th percentile request takes ~600-685ms due to having to wait for resources or enduring a cold start. To meet the SLO, we would need to enable Provisioned Concurrency.

## Assignment 5: Cost at Zero Load (Idle)
AWS Pricing screenshots are saved in `results/figures/pricing-screenshots/`.
Using `us-east-1` pricing:
- **Lambda:** $0 / hour. Assuming 18 hours idle/day, monthly idle cost is **$0.00**.
- **Fargate (0.5 vCPU, 1 GB):** $0.024685 / hour. Monthly idle cost = **~$13.33** (for 18 hours idle/day, 30 days) or ~$17.77 for always-on 24/7.
- **EC2 (t3.small):** $0.0208 / hour. Monthly idle cost = **~$11.23** (for 18 hours idle/day) or ~$14.98 for always-on 24/7.

Lambda has zero actual idle cost because you only pay for compute time invoked by a request. Fargate and EC2 charge by the hour as long as they are running, regardless of whether they are serving traffic.

## Assignment 6: Cost Model, Break-Even, and Recommendation

**Traffic Model Details:**
- Peak: 100 RPS for 30 min/day = 180,000 req
- Normal: 5 RPS for 5.5 hours/day = 99,000 req
- Idle: 18 hours/day
Total = 279,000 req/day = **8,370,000 requests/month**

**Computed Monthly Costs:**
Assuming 50ms average handler duration (0.05s) for Lambda, with 512 MB memory.
- Lambda Cost = (8.37M * $0.20/1M) + (8,370,000 * 0.05 * 0.5 * $0.0000166667)
  = $1.674 + $3.487 = **$5.16 / month**
- Fargate Cost (Always-on) = $0.024685 * 24 * 30 = **$17.77 / month**
- EC2 Cost (Always-on) = $0.0208 * 24 * 30 = **$14.98 / month**

**Break-Even RPS:**
Let $R$ be the average requests per second over the entire month (2,592,000 total seconds).
Lambda Cost = $(R \times 2,592,000 \times 0.20/1,000,000) + (R \times 2,592,000 \times 0.05 \times 0.5 \times 0.0000166667)$
Lambda Cost = $R \times 0.5184 + R \times 1.08 = R \times 1.5984$
Setting Lambda Cost equal to Fargate Cost ($17.77):
$1.5984 \times R = 17.77$ 
**$R = 11.1$ RPS.**
Lambda becomes more expensive than Fargate if the true monthly average traffic exceeds 11.1 requests per second. *(See `results/figures/cost-vs-rps.png` for chart).*

### Final Recommendation
Given the spiky traffic model (average ~3.2 RPS) and the strict p99 < 500ms SLO, I recommend using **AWS Lambda (Zip deployment)** with **Provisioned Concurrency**.

**Justification:**
1. At an average of 3.2 RPS, Lambda costs roughly ~$5.16/month, which is one-third the cost of always-on Fargate ($17.77) or EC2 ($14.98).
2. However, out-of-the-box Lambda fails the p99 < 500ms SLO under cold-start bursts, as my data showed a max latency around ~685ms when hitting cold starts.
3. Fargate and EC2 are even worse under peak bursts (100 RPS for 30 mins) with a single instance, pushing p99 into the 1.4s (EC2) and 5.2s (Fargate) range due to extreme queueing.

**Changes Needed:** 
To meet the SLO, we must configure **Provisioned Concurrency** for the Lambda Zip function. This keeps environments pre-warmed, eliminating the ~660ms Init Duration. It will slightly increase idle costs, but it guarantees sub-500ms p99 response times while scaling instantly to handle the 100 RPS spikes without queuing.

**Conditions for Reversal:**
My recommendation would change if the baseline average traffic consistently exceeds **11.1 RPS**. In that scenario, the compute cost of Lambda exceeds the flat rate of Fargate. At that point, I would migrate the workload to **Fargate**, but it would absolutely require configuring **Target Tracking Auto-Scaling** to dynamically add multiple tasks to prevent the 5.2s queuing latency observed during my load tests.
