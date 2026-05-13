> [!WARNING]
> When using this in your Computational Biology 2526 Project, please reference this repository. As per the request of the professor and assistant.

# smap-revenant

A benchmarking harness for the Smap Haplotype package. Made for the Computational Biology course at Ghent University.

> [!NOTE]
> Make sure to take a look at the argument reference. Some arguments are important!

# Installation

To install you can either:

1. Download the shell script itself from the releases tab and place it anywhere inside your project (or where you want to call it from).
2. Run this oneliner to install the script inside of your PATH and run it from anywhere.

```sh
sudo mkdir -p /usr/local/bin && sudo curl -L https://github.com/alikznollet/smap-revenant/raw/main/src/revenant.sh -o /usr/local/bin/revenant && sudo chmod +x /usr/local/bin/revenant
```

# Quick Start

## 0. Prerequisites

The script uses a few tools that need to be downloaded. You will have to install the following:

* `awk`
* `hyperfine`
* `gnu-time`

You can do this using your favority package manager!

## 1. Initialize the environment

Ensure your virtual environment is set up at `.venv`. If running the following:

```sh
pip install --upgrade pip setuptools wheel
pip install -e .

source .venv/bin/activate
```

Works does not return any error messages then you should be all good to go!

## 2. Generate Reference data

The very first thing you should do is run the `update` command. This generates reference data that'll be used when benchmarking to see whether anything was broken during optimization.

```sh
revenant --update
```

## 3. Run Standard Benchmarks

Once references exist, run standard benchmarks to compare results and track performance.

```sh
revenant --runs 5 --warmup 1
```

# Argument Reference

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-u, --update` | Overwrites the reference files with current results. | `false` |
| `-c, --cores <int>` | Number of CPU cores SMAP should use. | `4` |
| `-d, --data-dir <path>` | Path to your `.tar.gz` dataset archives. | `./smap_data` |
| `-r, --ref-dir <path>` | Path where reference `.tsv` files are stored | `./reference_data` |
| `-s, --skip <name>` | Skip specific dataset ID (can be passed multiple times) | `[]` |
| `--runs <int>` | Number of times hyperfine executes each benchmark. | `5` |
| `--warmup <int>` | Number of "warmup" runs before timing begins. | `1` |
| `--smap-args <str>` | Override standardized SMAP haplotype flags | `-f 5 -c 30 -e dosage -i diploid -z 2` |

# Contributing

If you find any bugs or want to contribute to this repository you are free to do so.

> [!IMPORTANT]
> If you are a student in **Computational Biology 2526**, please ensure that your contributions follow the guidelines for collaborative work. If you use a modified version of this harness, don't forget to cite the original repo in your final report!
