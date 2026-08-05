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
    let rawAcceleration: [RawAccelerationSample]
    let hitRanges: [HitRange]
}

enum StrikeDetectorError: LocalizedError {
    case missingDeviceMotion
    case missingRawAcceleration
    case modelNotFound
    case invalidModelMetadata
    case missingPredictionOutput

    var errorDescription: String? {
        switch self {
        case .missingDeviceMotion:
            return "No device-motion binary is available for this recording."
        case .missingRawAcceleration:
            return "No 800 Hz raw-acceleration binary is available for this recording."
        case .modelNotFound:
            return "The strike detection model was not found in the app bundle."
        case .invalidModelMetadata:
            return "The model metadata is incomplete for inference."
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
        guard recording.deviceMotionURL != nil else {
            throw StrikeDetectorError.missingDeviceMotion
        }
        guard recording.rawAccelerometerURL != nil else {
            throw StrikeDetectorError.missingRawAcceleration
        }

        let configuration = try loadConfiguration()
        let decoded = try BinaryMotionReader().read(recording: recording)
        let modelSamples = decoded.deviceMotion.enumerated().compactMap { index, sample in
            index.isMultiple(of: 2) ? sample : nil
        }
        let modelHitRanges = try detectHits(in: modelSamples, configuration: configuration)
        let hitRanges = modelHitRanges.map { range in
            HitRange(
                lowerSample: range.lowerSample * 2,
                upperSample: min((range.upperSample * 2) + 1, decoded.deviceMotion.count - 1),
                peakProbability: range.peakProbability
            )
        }
        return RecordingAnalysis(
            samples: decoded.deviceMotion,
            rawAcceleration: decoded.rawAcceleration,
            hitRanges: hitRanges
        )
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

        guard featureMean.count == 11, featureStd.count == 11 else {
            throw StrikeDetectorError.invalidModelMetadata
        }

        cachedConfiguration = configuration
        return configuration
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
