# Analysis of the conflict between prophage and transformation

This repository contains the code for comparing the frequency of transformation and the distribution of prophage across bacterial species.

All analysis code is included in the repository. However, to comply with the terms of use of the MLST databases, which prohibits the large-scale redistribution of allele profiles and sequence type definitions (see [here](https://pubmlst.org/terms-conditions) and [here](https://bigsdb.pasteur.fr/policy/)), some data are only provided as minimal summaries to enable reproduction of the published analyses.

The raw data may be obtained from the original sources:

- [PubMLST BIGSdb](https://pubmlst.org/software/bigsdb)

- [Pasteur BIGSdb](https://bigsdb.pasteur.fr/)

- [PHASTER database](https://phaster.ca/)

To prepare the repository for reproducing the original analysis, the large files need to be extracted:

```
cd phaster_outputs/
tar xfz phaster_data.tar.gz
cd ..
```
