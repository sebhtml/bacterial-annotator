#!/bin/bash

bacterial-annotator -i data/Illumina_2x300bp_Ecoli_RayAssembly.fasta\
		    -g U00096.3\
		    --remotedb nr\
		    -o Ecoli-RayAssembly-Annotation-REF+NRremote\
		    -f

