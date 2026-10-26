---
title: "Rig State Definitions and Connection Time KPIs"
subtitle: "Lab sample document (synthetic). Not operational guidance."
---

# Rig states used in the data model

Each 1-minute record in RAW.TAG_VALUE carries a rig state and a stand number.

| State | Definition |
|---|---|
| DRILLING | Bit on bottom, rotating or sliding, making hole |
| CONNECTION | Adding a stand: off bottom, in slips, making up the connection |
| CIRCULATING | Off bottom, pumps on, cleaning the hole |
| TRIPPING | Pulling out or running in the hole |
| NPT | Non-productive time, for example stuck pipe or equipment failure |

A **stand** is three joints of drill pipe, about 90 feet. The stand number increases as the well deepens.

# Connection time KPI

Connection time is the slips-to-slips duration of a CONNECTION state. Typical top-quartile performance on high-spec land rigs is under 4 minutes. Track the median per rig per day and investigate rigs whose median rises by more than one minute day over day.

# Weight-to-weight time

Weight-to-weight time runs from the last weight on bit before a connection to the first weight on bit after it. It includes reaming, surveys and the connection itself, and is a better measure of total flat time per stand than slips-to-slips.

# Why state matters for analytics

Most drilling analytics are only meaningful within a state. Average torque across a whole day mixes on-bottom and off-bottom values and hides precursors. Filter by state before aggregating: for example, compute torque trends only for DRILLING minutes, and hookload overpull only at CONNECTION boundaries.
