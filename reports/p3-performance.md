# P3 Yjs/Yrs performance benchmark

Single-machine Windows measurement from the standalone `yjs_probe`. Runtime bootstrap and DLL load are excluded; each row measures the same workload after a warmup document. Values are milliseconds.

| Runtime | Workload | Min | Median | Max |
|---|---|---:|---:|---:|
| Yjs | local inserts (50) | 7.280 | 9.379 | 10.287 |
| Yjs | format ranges (10) | 2.001 | 2.055 | 4.893 |
| Yjs | projection | 0.231 | 0.376 | 3.766 |
| Yjs | encodeStateAsUpdate | 0.371 | 0.513 | 0.693 |
| Yrs | local inserts (50) | 0.912 | 1.155 | 1.554 |
| Yrs | format ranges (10) | 0.336 | 0.440 | 0.512 |
| Yrs | projection | 0.106 | 0.134 | 0.544 |
| Yrs | encodeStateAsUpdate | 0.032 | 0.044 | 0.067 |

This is directional evidence for the exact versions and workload, not an adoption threshold. Repeat on representative Promeo hardware and with production-sized documents before making a performance decision.
