# Fae Security-Autonomy Launch SLOs

## Purpose

Define measurable launch criteria balancing:
- user autonomy (low friction)
- safety effectiveness (low unsafe escapes)
- runtime overhead (acceptable latency)

## SLO set

## 1) Interruption rate

**Metric:** confirmations per 100 completed user tasks  
**Target (Balanced):** <= 12/100  
**Alert:** > 20/100 over 24h dogfood window

## 2) Unsafe-action escape rate

**Metric:** blocked-by-policy actions that still execute (should be impossible)  
**Target:** 0  
**Alert:** any non-zero event blocks release

## 3) Default-deny coverage

**Metric:** percentage of executable action paths evaluated by broker  
**Target:** 100%  
**Alert:** < 100% blocks release

## 4) Rollback success

**Metric:** successful restore operations / attempted restores for reversible actions  
**Target:** >= 99%  
**Alert:** < 97%

## 5) Decision latency overhead

**Metric:** median broker decision latency  
**Target:** <= 15 ms  
**P95 target:** <= 50 ms

## 6) Security log integrity

**Metric:** events persisted / events emitted  
**Target:** >= 99.9%  
**Alert:** < 99.0%

## 7) Redaction quality

**Metric:** sampled sensitive-string leak rate in logs/analytics  
**Target:** 0 critical leaks  
**Alert:** any critical leak blocks release

## 8) Relay command policy compliance

**Metric:** unknown relay commands denied by default  
**Target:** 100%  
**Alert:** any unknown relay command accepted blocks release

## 9) Skill integrity enforcement

**Metric:** tampered executable skills blocked/disabled during discovery or execution  
**Target:** 100%  
**Alert:** any tampered executable skill runs

## 10) Outbound guardrail effectiveness

**Metric:** novel recipient sends confirmed + sensitive payload sends denied (sampled adversarial set)  
**Target:** 100%  
**Alert:** any missed deny/confirm in adversarial validation

## Release gate

A build is launch-eligible only if:
- unsafe-action escape rate is zero
- broker coverage is 100%
- interruption and latency targets are within threshold
- no critical redaction failures are found
