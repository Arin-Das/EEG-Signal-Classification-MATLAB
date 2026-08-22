# EEG Clinical Spectrum Analyzer

### Multi-Channel EEG Band Power Analysis and Reporting System

A MATLAB App Designer-based application developed for EEG signal analysis. The system processes EEG recordings and provides frequency-domain analysis, EEG band-power estimation, visualization, and automated descriptive interpretation.

## Project Overview

The **EEG Clinical Spectrum Analyzer** provides a user-friendly environment for analyzing EEG signals. It supports EEG data loading, signal visualization, frequency-band analysis, multi-channel processing, and generation of analysis results.

## Main Features

* EEG signal file loading
* Raw EEG signal visualization
* Multi-channel EEG processing
* FFT and spectral analysis
* Welch power spectral density analysis
* EEG frequency-band analysis
* Delta: 0.5–4 Hz
* Theta: 4–8 Hz
* Alpha: 8–13 Hz
* Beta: 13–30 Hz
* Absolute and relative band-power analysis
* EEG spectral pattern analysis
* Descriptive brain-state estimation
* Detection of selected spectral patterns
* Statistical and graphical analysis
* Data-sheet export
* Clinical-style EEG analysis summary

## Software and Requirements

* MATLAB
* MATLAB App Designer
* Recommended MATLAB version: R2024a or compatible version
* Signal Processing Toolbox may be required for some signal-processing functions

## Main Application

The main application file is:

`EEGAppBands.mlapp`

Additional MATLAB `.m` files required by the application are included in this repository.

## How to Run

1. Download or clone this repository.
2. Open MATLAB.
3. Open `EEGAppBands.mlapp` using App Designer.
4. Make sure the required MATLAB functions are in the same folder or MATLAB path.
5. Run the application.
6. Load a compatible EEG recording.
7. Perform EEG signal and frequency-band analysis.

## EEG Frequency Bands

| Band  | Frequency Range |
| ----- | --------------- |
| Delta | 0.5–4 Hz        |
| Theta | 4–8 Hz          |
| Alpha | 8–13 Hz         |
| Beta  | 13–30 Hz        |

## Project Purpose

This project was developed as an undergraduate academic project in the field of **Medical Physics and Biomedical Engineering**. It demonstrates the application of digital signal processing and EEG analysis techniques in a MATLAB-based graphical user interface.

## Author

**Koishik Das Arin**

Medical Physics and Biomedical Engineering

## Copyright

© 2026 Koishik Das Arin. All rights reserved.

The source code in this repository is an original academic project. No part of the source code may be reproduced, modified, redistributed, or used for commercial purposes without permission from the author, except where permitted by applicable law.

## Disclaimer

This software is intended for **academic, research, and educational purposes only**. The generated EEG interpretations are descriptive and are **not intended to replace professional clinical diagnosis or medical judgment**.
