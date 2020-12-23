#!/usr/bin/env python3

""" Randomly create BED intervals from referenceBED based on
    length in sampleBED  """

import sys
import random
import logging
import argparse
from bedgraphUtils import Bed
from utilities import setDefaults, createMainParent


__version__ = '1.0.0'


def sampleIntervals(bed: str, nRepeats: int, length: int, seed: float):
    random.seed(seed)
    allEntries = readBed(bed)
    # Select BEDS, weight by length, with replacement
    selections = random.choices(
        list(allEntries.keys()),
        weights=list(allEntries.values()), k=nRepeats)
    for selection in selections:
        pos = random.choice(selection.interval)
        print(selection.chrom, pos, pos + length, sep='\t')


def readBed(file):
    allEntries = {}
    with open(file) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            entry = Bed(line)
            allEntries[entry] = entry.regionLength
    return allEntries


def parseArgs():

    epilog = 'Stephen Richer, University of Bath, Bath, UK (sr467@bath.ac.uk)'
    mainParent = createMainParent(verbose=False, version=__version__)
    parser = argparse.ArgumentParser(
        epilog=epilog, description=__doc__, parents=[mainParent])

    parser.add_argument(
        'bed', metavar='BED',
        help='BED intervals within which regions will be sampled .')
    parser.add_argument(
        '--length', default=1, type=int,
        help='The length of the intervals to generate.')
    parser.add_argument(
        '--nRepeats', default=100_000, type=int,
        help='Number of intervals to generate samples (default: %(default)s).')
    parser.add_argument(
        '--seed', default=None, type=float,
        help='Seed for random number generation (default: %(default)s)')
    parser.set_defaults(function=sampleIntervals)

    return setDefaults(parser)


if __name__ == '__main__':
    args, function = parseArgs()
    sys.exit(function(**vars(args)))
