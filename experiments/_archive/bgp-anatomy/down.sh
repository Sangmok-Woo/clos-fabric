#!/bin/bash
cd "$(dirname "$0")" && containerlab destroy -t bgp.clab.yml --cleanup
