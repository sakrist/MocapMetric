import Foundation
import CoreML

struct MotionSample: Identifiable {
    let id: Int
    let timestamp: Double
    let ax: Double
    let ay: Double
    let az: Double
    let gx: Double
    let gy: Double
    let gz: Double
    let grx: Double
    let gry: Double
    let grz: Double
    let accMagnitude: Double
    let gyroMagnitude: Double
}

struct HitRange: Identifiable {
    let lowerSample: Int
    let upperSample: Int
    let peakProbability: Double

    var id: String {
        "\(lowerSample)-\(upperSample)"
    }

    var sampleRangeLabel: String {
        "\(lowerSample)-\(upperSample)"
    }
}

struct RecordingAnalysis {
    let samples: [MotionSample]
    let hitRanges: [HitRange]
}

enum StrikeDetectorError: LocalizedError {
    case missingCSV
    case modelNotFound
    case invalidModelMetadata
    case invalidCSV
    case missingPredictionOutput

    var errorDescription: String? {
        switch self {
        case .missingCSV:
            return "No CSV file is available for this recording."
        case .modelNotFound:
            return "The strike detection model was not found in the app bundle."
        case .invalidModelMetadata:
            return "The model metadata is incomplete for inference."
        case .invalidCSV:
            return "The CSV file could not be parsed."
        case .missingPredictionOutput:
            return "The model output is missing."
        }
    }
}

actor StrikeDetector {
    static let shared = StrikeDetector()

    private struct ModelConfiguration {
        let model: MLModel
        let featureMean: [Double]
        let featureStd: [Double]
        let windowSize: Int
        let stride: Int
        let threshold: Double
        let maxHitSamples: Int
    }

    private var cachedConfiguration: ModelConfiguration?

    func analyze(recording: RecordingSession) throws -> RecordingAnalysis {
        guard let csvURL = recording.csvURL else {
            throw StrikeDetectorError.missingCSV
        }

        let configuration = try loadConfiguration()
        let samples = try loadSamples(from: csvURL)
        let hitRanges = try detectHits(in: samples, configuration: configuration)
        return RecordingAnalysis(samples: samples, hitRanges: hitRanges)
    }

    private func loadConfiguration() throws -> ModelConfiguration {
        if let cachedConfiguration {
            return cachedConfiguration
        }

        let modelURL: URL
        if let compiledURL = Bundle.main.url(forResource: "strike-cnn-v1", withExtension: "mlmodelc") {
            modelURL = compiledURL
        } else if let packageURL = Bundle.main.url(forResource: "strike-cnn-v1", withExtension: "mlpackage") {
            modelURL = try MLModel.compileModel(at: packageURL)
        } else {
            throw StrikeDetectorError.modelNotFound
        }

        let model = try MLModel(contentsOf: modelURL)
        guard
            let creatorMetadata = model.modelDescription.metadata[.creatorDefinedKey] as? NSDictionary,
            let featureMeanJSON = creatorMetadata["feature_mean"] as? String,
            let featureStdJSON = creatorMetadata["feature_std"] as? String,
            let featureMean = parseDoubleArray(json: featureMeanJSON),
            let featureStd = parseDoubleArray(json: featureStdJSON)
        else {
            throw StrikeDetectorError.invalidModelMetadata
        }

        let windowSize = parseIntValue(creatorMetadata["window_size"]) ?? 70
        let stride = parseIntValue(creatorMetadata["stride"]) ?? 8
        let threshold = parseDoubleValue(creatorMetadata["threshold"]) ?? 0.5

        let configuration = ModelConfiguration(
            model: model,
            featureMean: featureMean,
            featureStd: featureStd,
            windowSize: windowSize,
            stride: stride,
            threshold: threshold,
            maxHitSamples: 80
        )

        cachedConfiguration = configuration
        return configuration
    }

    private func loadSamples(from csvURL: URL) throws -> [MotionSample] {
        let contents = try String(contentsOf: csvURL, encoding: .utf8)
        let rows = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard let headerRow = rows.first else {
            throw StrikeDetectorError.invalidCSV
        }

        let headers = headerRow.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let indexByColumn = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })

        let requiredColumns = ["timestamp", "ax", "ay", "az", "gx", "gy", "gz", "grx", "gry", "grz"]
        guard requiredColumns.allSatisfy({ indexByColumn[$0] != nil }) else {
            throw StrikeDetectorError.invalidCSV
        }

        var samples: [MotionSample] = []

        for row in rows.dropFirst() {
            let values = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

            guard
                let timestamp = doubleValue(for: "timestamp", in: values, using: indexByColumn),
                let ax = doubleValue(for: "ax", in: values, using: indexByColumn),
                let ay = doubleValue(for: "ay", in: values, using: indexByColumn),
                let az = doubleValue(for: "az", in: values, using: indexByColumn),
                let gx = doubleValue(for: "gx", in: values, using: indexByColumn),
                let gy = doubleValue(for: "gy", in: values, using: indexByColumn),
                let gz = doubleValue(for: "gz", in: values, using: indexByColumn),
                let grx = doubleValue(for: "grx", in: values, using: indexByColumn),
                let gry = doubleValue(for: "gry", in: values, using: indexByColumn),
                let grz = doubleValue(for: "grz", in: values, using: indexByColumn)
            else {
                continue
            }

            let accMagnitude = magnitude(x: ax, y: ay, z: az)
            let gyroMagnitude = magnitude(x: gx, y: gy, z: gz)

            samples.append(
                MotionSample(
                    id: samples.count,
                    timestamp: timestamp,
                    ax: ax,
                    ay: ay,
                    az: az,
                    gx: gx,
                    gy: gy,
                    gz: gz,
                    grx: grx,
                    gry: gry,
                    grz: grz,
                    accMagnitude: accMagnitude,
                    gyroMagnitude: gyroMagnitude
                )
            )
        }

        guard !samples.isEmpty else {
            throw StrikeDetectorError.invalidCSV
        }

        return samples
    }

    private func detectHits(in samples: [MotionSample], configuration: ModelConfiguration) throws -> [HitRange] {
        guard samples.count >= configuration.windowSize else {
            return []
        }

        var candidateRanges: [(range: ClosedRange<Int>, probability: Double)] = []

        for startIndex in stride(from: 0, through: samples.count - configuration.windowSize, by: configuration.stride) {
            let inputArray = try MLMultiArray(shape: [1, 11, NSNumber(value: configuration.windowSize)], dataType: .float32)

            for sampleOffset in 0..<configuration.windowSize {
                let sample = samples[startIndex + sampleOffset]
                let featureVector = [
                    sample.ax,
                    sample.ay,
                    sample.az,
                    sample.gx,
                    sample.gy,
                    sample.gz,
                    sample.grx,
                    sample.gry,
                    sample.grz,
                    sample.accMagnitude,
                    sample.gyroMagnitude,
                ]

                for featureIndex in 0..<featureVector.count {
                    let normalized = normalize(
                        featureVector[featureIndex],
                        mean: configuration.featureMean[featureIndex],
                        std: configuration.featureStd[featureIndex]
                    )
                    inputArray[[0, NSNumber(value: featureIndex), NSNumber(value: sampleOffset)]] = NSNumber(value: Float(normalized))
                }
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "imu_window": MLFeatureValue(multiArray: inputArray),
            ])
            let prediction = try configuration.model.prediction(from: provider)
            guard
                let outputArray = prediction.featureValue(for: "strike_probability")?.multiArrayValue
            else {
                throw StrikeDetectorError.missingPredictionOutput
            }

            let probability = outputArray[[0]].doubleValue
            if probability >= configuration.threshold {
                let range = startIndex...(startIndex + configuration.windowSize - 1)
                candidateRanges.append((range, probability))
            }
        }

        return mergeRanges(
            candidateRanges,
            stride: configuration.stride,
            maxHitSamples: configuration.maxHitSamples
        )
    }

    private func mergeRanges(
        _ candidateRanges: [(range: ClosedRange<Int>, probability: Double)],
        stride: Int,
        maxHitSamples: Int
    ) -> [HitRange] {
        guard let first = candidateRanges.first else { return [] }

        var merged: [HitRange] = []
        var currentLower = first.range.lowerBound
        var currentUpper = first.range.upperBound
        var currentPeak = first.probability
        var currentPeakRange = first.range

        for candidate in candidateRanges.dropFirst() {
            if candidate.range.lowerBound <= currentUpper + stride {
                currentUpper = max(currentUpper, candidate.range.upperBound)
                if candidate.probability >= currentPeak {
                    currentPeak = candidate.probability
                    currentPeakRange = candidate.range
                }
            } else {
                merged.append(
                    buildHitRange(
                        mergedLower: currentLower,
                        mergedUpper: currentUpper,
                        peakRange: currentPeakRange,
                        peakProbability: currentPeak,
                        maxHitSamples: maxHitSamples
                    )
                )
                currentLower = candidate.range.lowerBound
                currentUpper = candidate.range.upperBound
                currentPeak = candidate.probability
                currentPeakRange = candidate.range
            }
        }

        merged.append(
            buildHitRange(
                mergedLower: currentLower,
                mergedUpper: currentUpper,
                peakRange: currentPeakRange,
                peakProbability: currentPeak,
                maxHitSamples: maxHitSamples
            )
        )
        return merged
    }

    private func buildHitRange(
        mergedLower: Int,
        mergedUpper: Int,
        peakRange: ClosedRange<Int>,
        peakProbability: Double,
        maxHitSamples: Int
    ) -> HitRange {
        let mergedLength = mergedUpper - mergedLower + 1
        guard mergedLength > maxHitSamples else {
            return HitRange(
                lowerSample: mergedLower,
                upperSample: mergedUpper,
                peakProbability: peakProbability
            )
        }

        let peakCenter = (peakRange.lowerBound + peakRange.upperBound) / 2
        let halfWidth = maxHitSamples / 2

        var lower = peakCenter - halfWidth
        var upper = lower + maxHitSamples - 1

        if lower < mergedLower {
            lower = mergedLower
            upper = lower + maxHitSamples - 1
        }

        if upper > mergedUpper {
            upper = mergedUpper
            lower = upper - maxHitSamples + 1
        }

        return HitRange(
            lowerSample: lower,
            upperSample: upper,
            peakProbability: peakProbability
        )
    }

    private func normalize(_ value: Double, mean: Double, std: Double) -> Double {
        guard std != 0 else { return value - mean }
        return (value - mean) / std
    }

    private func magnitude(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }

    private func doubleValue(for key: String, in row: [String], using indexByColumn: [String: Int]) -> Double? {
        guard let index = indexByColumn[key], index < row.count else {
            return nil
        }
        return Double(row[index])
    }

    private func parseDoubleArray(json: String) -> [Double]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Double].self, from: data)
    }

    private func parseIntValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func parseDoubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }
}
