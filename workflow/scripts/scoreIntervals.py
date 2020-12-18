#!/usr/bin/env python3

""" Summarise bedgraph score per interval region """

import sys
import argparse
from collections import defaultdict
from utilities import setDefaults, createMainParent
from bedgraphUtils import splitScore, readRegions


__version__ = '1.0.0'


def scoreIntervals(bedGraph: str, bed: str, name: str, out: str, format: str):
    regions = readRegions(bed)
    scoredRegions = defaultdict(float)
    with open(bedGraph) as fh:
        for i, line in enumerate(fh):
            chrom, start, end, score = splitScore(line, format)
            for interval in regions[chrom]:
                # Detect base overlap between bedgraph interval and each region
                overlap = range(max(start, min(interval)), min(end, max(interval))+1)
                if overlap:
                    regionLength = end - start
                    key = f'{chrom}-{min(interval)}-{max(interval)+1}'
                    scoredRegions[key] += (score / regionLength) * len(overlap)
    print(scoredRegions)


def parseArgs():

    epilog = 'Stephen Richer, University of Bath, Bath, UK (sr467@bath.ac.uk)'
    mainParent = createMainParent(verbose=False, version=__version__)
    parser = argparse.ArgumentParser(
        epilog=epilog, description=__doc__, parents=[mainParent])

    parser.add_argument(
        'bedGraph', help='BedGraph/BED interval file to rescale.')
    parser.add_argument(
        'bed', metavar='BED', help='BED file indicating regions to process.')
    parser.add_argument(
        '--name', help='Name to store in metadata. Defaults to infile path.')
    requiredNamed = parser.add_argument_group('required named arguments')
    requiredNamed.add_argument(
        '--out', required=True,
        help='Path to save pickled dataframe.')
    requiredNamed.add_argument(
        '--format',  required=True, choices=['bed', 'bedgraph'],
        help='Input format to correctly retrive score column.')
    parser.set_defaults(function=scoreIntervals)

    return setDefaults(parser)


if __name__ == '__main__':
    args, function = parseArgs()
    sys.exit(function(**vars(args)))
