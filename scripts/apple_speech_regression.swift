#!/usr/bin/env swift

import AVFoundation
import Foundation
import Speech

struct ResultRow: Codable {
    let file: String
    let text: String
    let elapsedSeconds: Double
    let error: String?
}

@available(macOS 26.0, *)
func transcribe(_ url: URL) async -> ResultRow {
    let clock = ContinuousClock()
    let started = clock.now
    do {
        let audioFile = try AVAudioFile(forReading: url)
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "zh_CN")
        ) else {
            throw NSError(domain: "AppleSpeechRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zh_CN unsupported"])
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let resultTask = Task { () throws -> String in
            var finalized = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    volatile = ""
                } else {
                    volatile = text
                }
            }
            return finalized.isEmpty ? volatile : finalized
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await resultTask.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ResultRow(
            file: url.lastPathComponent,
            text: text,
            elapsedSeconds: elapsed(started, clock.now),
            error: nil
        )
    } catch {
        return ResultRow(
            file: url.lastPathComponent,
            text: "",
            elapsedSeconds: elapsed(started, clock.now),
            error: String(describing: error)
        )
    }
}

func elapsed(
    _ start: ContinuousClock.Instant,
    _ end: ContinuousClock.Instant
) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds)
        + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

guard #available(macOS 26.0, *) else {
    fputs("macOS 26 or later is required\n", stderr)
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var outputURL: URL?
if let outputIndex = arguments.firstIndex(of: "--output"),
   arguments.indices.contains(outputIndex + 1) {
    outputURL = URL(fileURLWithPath: NSString(
        string: arguments[outputIndex + 1]
    ).expandingTildeInPath)
    arguments.removeSubrange(outputIndex...(outputIndex + 1))
}
guard !arguments.isEmpty else {
    fputs("usage: apple_speech_regression.swift [--output FILE] WAV_OR_DIRECTORY [...]\n", stderr)
    exit(2)
}

var urls: [URL] = []
for argument in arguments {
    let url = URL(fileURLWithPath: NSString(string: argument).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
       isDirectory.boolValue {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        urls.append(contentsOf: children.filter { $0.pathExtension.lowercased() == "wav" })
    } else {
        urls.append(url)
    }
}
urls = Array(Set(urls)).sorted { $0.lastPathComponent < $1.lastPathComponent }

Task {
    var rows: [ResultRow] = []
    for (index, url) in urls.enumerated() {
        fputs("[\(index + 1)/\(urls.count)] \(url.lastPathComponent)\n", stderr)
        rows.append(await transcribe(url))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(rows)
    if let outputURL {
        try! (data + Data("\n".utf8)).write(to: outputURL, options: .atomic)
        fputs("report=\(outputURL.path)\n", stderr)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(rows.contains { $0.error != nil } ? 1 : 0)
}
dispatchMain()
