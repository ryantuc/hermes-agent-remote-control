#if DEBUG
import Foundation
import HermesServeKit
import os

/// Offline fixtures for the screenshot harness's model-settings routes: a config document with every row of Model & reasoning present, and a small catalogue for the picker, so the rows and the editors can be photographed with no backend.
enum ModelSettingsDemo {
    static let log = Logger(subsystem: "com.hermes.mobile.app", category: "screenshot")

    static var isScreenshotting: Bool {
        ProcessInfo.processInfo.arguments.contains("-hermesScreenshotRoute")
    }

    /// The row whose editor a route wants opened on arrival; consumed by the first screen that carries it.
    static var autoOpenKey: String?

    static var catalogueIfScreenshotting: ModelCatalogue? {
        isScreenshotting ? catalogue : nil
    }

    static let document: JSONValue = .object([
        "model": .string("anthropic/claude-sonnet-4.6"),
        "model_context_length": .number(0),
        "fallback_providers": .array([
            .object(["provider": .string("nous"), "model": .string("hermes-4-405b")]),
            .object(["provider": .string("openrouter"), "model": .string("google/gemini-3-flash-preview")]),
        ]),
        "agent": .object(["reasoning_effort": .string("medium")]),
        "display": .object(["show_reasoning": .bool(true)]),
        "delegation": .object([
            "reasoning_effort": .string(""),
            "provider": .string(""),
            "model": .string(""),
        ]),
        "auxiliary": .object([
            "vision": .object(["provider": .string("auto"), "model": .string("")]),
            "compression": .object(["provider": .string("openrouter"), "model": .string("google/gemini-3-flash-preview")]),
            "title_generation": .object(["provider": .string("auto"), "model": .string("")]),
        ]),
    ])

    static let catalogue = ModelCatalogue(json: .object([
        "providers": .array([
            .object([
                "slug": .string("anthropic"), "name": .string("Anthropic"),
                "is_current": .bool(true), "authenticated": .bool(true),
                "models": .array([
                    .object(["slug": .string("claude-sonnet-4.6"), "name": .string("Claude Sonnet 4.6"), "is_current": .bool(true)]),
                    .object(["slug": .string("claude-opus-4.6"), "name": .string("Claude Opus 4.6")]),
                    .object(["slug": .string("claude-haiku-4.5"), "name": .string("Claude Haiku 4.5")]),
                ]),
            ]),
            .object([
                "slug": .string("nous"), "name": .string("Nous Research"),
                "authenticated": .bool(true),
                "models": .array([
                    .object(["slug": .string("hermes-4-405b"), "name": .string("Hermes 4 405B")]),
                    .object(["slug": .string("hermes-4-70b"), "name": .string("Hermes 4 70B")]),
                ]),
            ]),
            .object([
                "slug": .string("openrouter"), "name": .string("OpenRouter"),
                "authenticated": .bool(true),
                "models": .array([
                    .object(["slug": .string("google/gemini-3-flash-preview"), "name": .string("Gemini 3 Flash")]),
                    .object(["slug": .string("deepseek/deepseek-v4-flash-0731"), "name": .string("DeepSeek V4 Flash")]),
                ]),
            ]),
            .object([
                "slug": .string("openai-codex"), "name": .string("OpenAI Codex"),
                "authenticated": .bool(false), "warning": .string("No login saved for this provider."),
                "models": .array([
                    .object(["slug": .string("gpt-5.4-mini"), "name": .string("GPT-5.4 mini")]),
                ]),
            ]),
        ]),
    ]))
}
#endif
