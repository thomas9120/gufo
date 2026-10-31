// Windows YaRN checkpoint coverage without the Linux snapshot fault hooks.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "src/core/sampling.hpp"
#include "src/models/qwen38_flash_next/engine.hpp"

namespace qfn = gufo::models::qwen38_flash_next;

namespace {
void Require(bool condition, const std::string& message) {
  if (!condition)
    throw std::runtime_error(message);
}

struct Result {
  std::vector<std::int32_t> tokens;
  std::size_t drafted{}, accepted{};
  bool operator==(const Result&) const = default;
};

Result Decode(qfn::Session& session) {
  const auto history = session.Tokens();
  const std::vector<gufo::sampling::TokenId> initial(history.begin(),
                                                     history.end());
  gufo::sampling::SamplerState sampler({.temperature = 0.0F}, initial);
  const auto before = session.Statistics();
  Result result;
  std::string error;
  while (result.tokens.size() < 16) {
    qfn::Session::DecodeResult step;
    Require(session.DecodeStep(16 - result.tokens.size(), sampler, &step,
                               &error, false),
            error);
    Require(!step.tokens.empty(), "empty decode step");
    result.tokens.insert(result.tokens.end(), step.tokens.begin(),
                         step.tokens.end());
  }
  const auto after = session.Statistics();
  result.drafted = after.drafted - before.drafted;
  result.accepted = after.accepted - before.accepted;
  return result;
}

std::vector<std::uint8_t> CheckCheckpoint(
    const std::shared_ptr<qfn::Model>& model, gufo::core::SessionMode mode,
    bool extended) {
  std::string error;
  auto session = model->CreateSession(mode, model->MaxContext(), &error);
  Require(session != nullptr, error);
  const auto pattern = model->Tokenize("Continue: red, blue, green. ");
  Require(!pattern.empty(), "empty prompt pattern");
  const std::uint32_t boundary = extended ? 262145 : 4093;
  std::vector<std::int32_t> prompt(boundary + 7);
  for (std::size_t i = 0; i < prompt.size(); ++i)
    prompt[i] = pattern[i % pattern.size()];
  Require(session->Sync(std::span(prompt).first(boundary - 11), &error), error);
  auto warm = session->SaveSnapshot(&error);
  Require(warm != nullptr, error);
  const auto claim = session->PrefillCheckpointBytes(boundary);
  std::unique_ptr<qfn::SessionSnapshot> checkpoint;
  double capture_ms = -1;
  Require(
      session->SyncThrough(prompt, boundary, &checkpoint, &error, &capture_ms),
      error);
  Require(checkpoint && checkpoint->SizeBytes() == claim &&
              std::isfinite(capture_ms) && capture_ms > 0,
          "checkpoint differs from its admission claim");
  const std::vector<float> final_logits(session->Logits().begin(),
                                        session->Logits().end());
  const auto expected = Decode(*session);
  if (mode == gufo::core::SessionMode::kSpeculative)
    Require(expected.drafted > 0, "MTP produced no actual drafts");
  Require(session->RestoreSnapshot(*checkpoint, &error), error);
  const std::vector<float> boundary_logits(session->Logits().begin(),
                                           session->Logits().end());
  std::vector<std::uint8_t> bytes;
  if (!extended) {
    bytes.resize(checkpoint->SizeBytes());
    Require(checkpoint->CopyTo(bytes), "serialize checkpoint");
    constexpr std::array<std::uint8_t, 8> magic{'Q', 'F', 'N', 'S',
                                                'N', 'A', 'P', '6'};
    const auto executor =
        std::search(bytes.begin(), bytes.end(), magic.begin(), magic.end());
    Require(executor != bytes.end(), "executor snapshot header is missing");
    executor[7] = '5';  // The executor format immediately before YaRN.
    Require(!session->RestoreSnapshot(bytes, &error),
            "pre-YaRN snapshot version was accepted");
    // Inner restore failures reset the slot; verify exact cold recovery.
    Require(session->Position() == 0 && session->Tokens().empty(),
            "incompatible executor payload did not reset the slot");
    // Match the original prefill boundaries for the bitwise recovery control.
    Require(session->Sync(std::span(prompt).first(boundary - 11), &error),
            error);
    Require(session->Sync(std::span(prompt).first(boundary), &error), error);
    Require(session->Sync(prompt, &error), error);
    Require(std::memcmp(final_logits.data(), session->Logits().data(),
                        session->Logits().size_bytes()) == 0 &&
                Decode(*session) == expected,
            "recompute after an incompatible snapshot differs");
    executor[7] = '6';
    Require(session->RestoreSnapshot(bytes, &error), error);
    Require(session->Position() == boundary &&
                std::memcmp(boundary_logits.data(), session->Logits().data(),
                            session->Logits().size_bytes()) == 0,
            "serialized checkpoint changed boundary state");
    Require(session->Sync(prompt, &error), error);
    Require(std::memcmp(final_logits.data(), session->Logits().data(),
                        session->Logits().size_bytes()) == 0,
            "serialized checkpoint changed split-pass logits");
    Require(Decode(*session) == expected,
            "serialized checkpoint continuation differs");
  }
  Require(session->RestoreSnapshot(*warm, &error), error);
  checkpoint.reset();
  Require(session->Sync(std::span(prompt).first(boundary), &error), error);
  Require(std::memcmp(boundary_logits.data(), session->Logits().data(),
                      session->Logits().size_bytes()) == 0,
          "ordinary prefill changed checkpoint boundary logits");
  Require(session->Sync(prompt, &error), error);
  Require(std::memcmp(final_logits.data(), session->Logits().data(),
                      session->Logits().size_bytes()) == 0,
          "checkpoint changed split-pass logits");
  Require(Decode(*session) == expected, "checkpoint continuation differs");
  std::cout << "mode=" << static_cast<int>(mode) << " boundary=" << boundary
            << " exact=1 drafted=" << expected.drafted << '\n'
            << std::flush;
  return bytes;
}
}  // namespace

int main(int argc, char** argv) {
  const bool extended = argc == 6 && std::string_view(argv[5]) == "--extended";
  if ((argc != 5 && !extended) || std::string_view(argv[1]) != "--model" ||
      std::string_view(argv[3]) != "--mtp-model") {
    std::cerr
        << "Usage: win32_yarn_snapshot_test --model PATH --mtp-model PATH "
           "[--extended]\n";
    return 77;
  }
  try {
    const std::uint32_t context = extended ? 409600 : 8192;
    std::vector<std::vector<std::uint8_t>> snapshots;
    const auto modes = {gufo::core::SessionMode::kAutoregressive,
                        gufo::core::SessionMode::kSpeculative};
    std::string error;
    {
      auto model = qfn::Model::Load(
          argv[2],
          {.max_context = context,
           .mtp_model_path = argv[4],
           .max_draft_tokens = 7,
           .rope_scaling =
               qfn::RopeScaling{.factor = 1.5625F, .original_context = 262144}},
          &error);
      Require(model != nullptr, error);
      for (const auto mode : modes)
        snapshots.push_back(CheckCheckpoint(model, mode, extended));
    }
    if (!extended) {
      // Reload sequentially so the two models never occupy the GPU together.
      auto model = qfn::Model::Load(
          argv[2],
          {.max_context = context,
           .mtp_model_path = argv[4],
           .max_draft_tokens = 7,
           .rope_scaling =
               qfn::RopeScaling{.factor = 2.5F, .original_context = 262144}},
          &error);
      Require(model != nullptr, error);
      std::size_t i = 0;
      for (const auto mode : modes) {
        auto session = model->CreateSession(mode, context, &error);
        Require(session != nullptr, error);
        Require(!session->RestoreSnapshot(snapshots[i++], &error),
                "snapshot from a different YaRN factor was accepted");
        Require(session->Position() == 0, "rejection changed session state");
      }
      std::cout << "different-factor snapshots rejected\n";
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
