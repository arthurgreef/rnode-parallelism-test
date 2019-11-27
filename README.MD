This script is used to gather data for https://rchain.atlassian.net/browse/RCHAIN-3942.  
**Prerequisites: account in Google Compute Engine and gcloud configured required.**

Usage: 
```sh
./run-test <git repo url> <branch or commit hash> \
<contract to execute> <num of deployments> \
<num of iterations> <shut down instance after test finished (true/false)> \
<num of CPUs in instance(2,4,8,16,32)> 
```
E.g.  
```sh 
./run-test "https://github.com/rchain/rchain/" release-rnode-v0.9.17 \
"https://raw.githubusercontent.com/nzpr/rnode-parallelism-test/master/deploys/cpu-test9x1k.rho" 1 \
20 false 16
```  
This script starts Google Compute Engine instance, installs all prerequisites, builds particular version of rnode specified by commit and runs `<num of iterations>` tests, calculating play an replay execution time. Parameters of instance created are defined in `create-instance.sh`

Single test is: 
- clean RNode working folder
- start node
- deploy contract 
- propose block #1
- measure times of play and replay

Local Jaeger instance is collecting tracing spans and available via http. Please look into script output.
Flamegraphs are WIP.

## NOTICE!  
Play and replay execution times are measured via reading log messages.  
**Play** = between `Making a transition to Running` and `Attempting to add Block`  
**Replay** = between `Attempting to add Block` and  `Sent hash` (`Sent Block` in older releases).