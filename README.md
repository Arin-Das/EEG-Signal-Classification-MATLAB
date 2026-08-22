# EEG Clinical Spectrum Analyzer

### Multi-Channel EEG Band-Power Analysis and Reporting System

A MATLAB App Designer application for multi-channel EEG signal processing, spectral analysis, band-power estimation, visualization, signal-quality assessment, and descriptive EEG pattern analysis.

---

## Overview

The **EEG Clinical Spectrum Analyzer** is a MATLAB-based graphical application developed for academic, research, and educational use in EEG signal analysis.

The application allows users to load EEG recordings, preprocess signals, analyze frequency-domain characteristics, calculate absolute and relative EEG band power, assess signal quality, compare channels, identify descriptive spectral patterns, and generate analysis reports.

The system is designed as a **descriptive EEG analysis tool and not as a clinical diagnostic device**.

---

## Key Features

### EEG Data Import

The application supports:

- `.MAT` EEG files
- `.CSV` EEG files
- `.EDF` EEG recordings

For MATLAB files, the application expects an `EEG` variable and can use associated sampling-frequency and channel-name information when available.

---

## Signal Preprocessing

The EEG processing pipeline includes:

1. Linear detrending to reduce slow signal drift.
2. Narrow IIR notch filtering for power-line interference removal.
3. Zero-phase filtering using `filtfilt`.
4. Band-pass filtering for time-domain visualization.

The application uses a configurable notch frequency, with the default configuration designed for **50-Hz power-line interference**.

---

## EEG Frequency Bands

The application analyzes five frequency bands:

| Band | Frequency Range |
|---|---|
| Delta | 0.5–4 Hz |
| Theta | 4–8 Hz |
| Alpha | 8–13 Hz |
| Beta | 13–30 Hz |
| Gamma | 30–45 Hz |

Relative band power is calculated with respect to the broadband range of **0.5–45 Hz**.

---

## Spectral Analysis

The main EEG spectral analysis uses **Welch's Power Spectral Density (PSD) method**.

The application calculates:

- Absolute band power
- Relative band power
- Alpha peak frequency
- Broadband spectral information
- Signal-quality metrics

---

## Multi-Channel EEG Analysis

The application can analyze multiple EEG channels from the loaded recording.

For each channel, the system can provide:

- Frequency-band power
- Relative band-power distribution
- Dominant frequency band
- Alpha peak frequency
- Signal-quality information
- Generalized slowing observation
- Large-amplitude transient count
- Descriptive spectral pattern flags

The application also provides channel-overview and comparative analysis.

---

## Signal Quality Assessment

A signal-quality metric is calculated by identifying samples with unusually large amplitude excursions relative to the signal standard deviation.

This provides a quantitative indication of potentially problematic signal segments.

The quality measure is intended as an analytical indicator and should not be interpreted as a complete artifact-rejection or clinical EEG-quality assessment.

---

## Descriptive EEG Pattern Analysis

The application provides heuristic observations based on relative EEG band power.

Examples include:

- High Theta/Beta ratio
- High Delta/Alpha ratio
- Theta-dominant activity
- Alpha-dominant activity
- Beta-dominant activity
- Slow-wave dominant pattern
- Generalized low-frequency slowing

The application can also provide a dominant-band state description such as:

- Delta-dominant
- Theta-dominant
- Alpha-dominant
- Beta-dominant
- Gamma-dominant

These descriptions represent spectral characteristics of the analyzed signal and are **not clinical diagnoses**.

---

## Clinical EEG Pattern Flags

The application includes research/educational heuristic pattern flags related to selected EEG characteristics, including:

- Seizure-like activity
- Dementia-associated slowing pattern
- ADHD-associated Theta/Beta pattern
- Frontal alpha asymmetry

These flags are based on predefined heuristic thresholds implemented in the application.

**They are not validated diagnostic criteria and must not be used independently for clinical decision-making.**

---

## Hemispheric Asymmetry Analysis

The application can compare relative band power between compatible left/right EEG channel pairs.

Supported pair comparisons include standard electrode relationships such as:

- Fp1 / Fp2
- F3 / F4
- C3 / C4
- O1 / O2

The application also supports frontal-pair analysis using available channel names.

Asymmetry results are descriptive statistical comparisons and do not provide lesion localization or clinical lateralization.

---

## Large-Amplitude Transient Analysis

The application reports large-amplitude transient events using a standard-deviation-based threshold.

This feature is intended to identify potentially notable amplitude excursions.

It is **not an epileptiform spike detector** and should not be interpreted as automated seizure diagnosis.

---

## Visualization

The application provides graphical visualization of EEG signals and spectral information, including:

- Raw EEG waveform visualization
- Selected-band filtered waveform visualization
- Band-power charts
- Multi-channel band-power comparison
- Reference-range visualization
- Channel overview information
- Spectral analysis summaries

---

## Reports and Data Export

The application supports export of EEG analysis results.

### PDF Report

The generated report can contain:

- Analysis summary
- Channel overview
- Band-power information
- Signal-quality information
- Spectral observations
- Hemispheric asymmetry information
- Pattern flags
- EEG waveform visualizations
- Band-power charts

### Excel Data Export

The application can export structured analysis data containing information such as:

- Channel
- Frequency band
- Relative power
- Absolute power
- Reference range
- Status
- Signal-quality information
- Descriptive analysis summary

---

## Reference Ranges

The application includes illustrative relative-power reference ranges for comparison.

These ranges are intended for **educational and visualization purposes** and are not a clinically validated normative EEG database.

Therefore, values shown as:

- Below
- Within
- Above

should be interpreted as comparisons against the application's illustrative reference ranges rather than clinical abnormalities.

---

## Processing Pipeline

```text
EEG Recording
      |
      v
Data Import
(.MAT / .CSV / .EDF)
      |
      v
Channel & Sampling Rate Detection
      |
      v
Signal Preprocessing
      |
      +-- Linear Detrending
      |
      +-- Notch Filtering
      |
      v
EEG Signal Analysis
      |
      +-- Time-Domain Visualization
      |
      +-- Welch PSD Analysis
              |
              v
      Frequency-Band Power
              |
        +-----+-------+
        |     |       |
        v     v       v
    Absolute Relative Alpha
     Power    Power   Peak
        |      |       |
        +------+-------+
               |
               v
      Multi-Channel Analysis
               |
        +------+-------------+
        |      |             |
        v      v             v
     Quality Asymmetry  Pattern Analysis
      Check   Analysis    & Flags
        |      |             |
        +------+-------------+
               |
               v
       Analysis Summary
               |
          +----+----+
          |         |
          v         v
        PDF       Excel
       Report      Data

# Main Application File

The main MATLAB application is:

`EEGAppBands.m`

The application is implemented as a MATLAB App Designer class.

---

## Requirements

### Software

- MATLAB
- MATLAB App Designer
- Signal Processing Toolbox for functionality used by the application

### Recommended Environment

A relatively recent MATLAB release is recommended for compatibility with the application's App Designer interface and signal-processing functions.

---

## How to Run

1. Download or clone this repository.
2. Open MATLAB.
3. Add the project folder to the MATLAB path.
4. Open `EEGAppBands.m`.
5. Run the application.
6. Load a compatible EEG recording.
7. Select the required channel and frequency band.
8. Perform EEG analysis.
9. Review the spectral, quality, and descriptive pattern results.
10. Export the results when required.

---

## Project Purpose

This project was developed as an undergraduate academic project in **Medical Physics and Biomedical Engineering**.

It demonstrates the application of:

- Digital signal processing
- Biomedical signal analysis
- EEG spectral analysis
- Power spectral density estimation
- Frequency-band analysis
- Multi-channel EEG processing
- MATLAB App Designer
- Biomedical data visualization
- Automated descriptive reporting

---

## Limitations

This application has several important limitations:

- The pattern-detection methods are heuristic.
- The reference ranges are illustrative rather than clinically validated.
- Spectral pattern flags do not constitute medical diagnoses.
- Large-amplitude transient detection is not equivalent to epileptiform spike detection.
- Hemispheric asymmetry analysis does not localize brain lesions.
- EEG interpretation requires clinical context and expert review.
- The application should not be used as a standalone clinical diagnostic system.

---

## Disclaimer

**This software is intended for academic, research, and educational purposes only.**

The results produced by this application represent descriptive and heuristic EEG signal characteristics. They are **not intended to replace professional EEG interpretation, clinical assessment, or medical diagnosis**.

Clinical decisions should not be made solely on the basis of this software's output.

---

## Authors

- **Koishik Das Arin**
- **Shafiya Akter Liza**
- **Md. Tanvir Hossain Molla**

**Medical Physics & Biomedical Engineering**

---

## Copyright

© 2026 Koishik Das Arin, Shafiya Akter Liza, and Md. Tanvir Hossain Molla. All rights reserved.

This repository contains an academic software project developed by the authors. The source code may not be reproduced, redistributed, modified, or used for commercial purposes without permission from the authors, except where permitted by applicable law.
