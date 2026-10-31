#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <memory>
#include <string>
#include <thread>

#include "src/cli/serve/asr_service.hpp"
#include "src/cli/serve/audio_stream.hpp"
#include "src/cli/serve/http_server.hpp"
#include "src/cli/serve/tts_service.hpp"
#include "src/cli/serve/websocket.hpp"
#include "src/core/json.hpp"
// WINDOWS: exercise WebSocket transport on Winsock.
#include "src/core/platform/socket.hpp"

namespace {
// WINDOWS: keep native Winsock handles; gufo::platform wrappers replace net::.
using namespace gufo::server;
namespace json = gufo::json;

class Client {
public:
  Client(int port, std::string_view path, std::string first = {},
         std::string_view key = "dGhlIHNhbXBsZSBub25jZQ==",
         std::string_view authorization = "Bearer test") {
    fd = ::socket(AF_INET, SOCK_STREAM, 0);
    // WINDOWS: exercise WebSocket transport on Winsock.
    assert(fd != gufo::platform::kInvalidSocket);
    assert(gufo::platform::SetSocketTimeout(fd, SO_RCVTIMEO,
                                            std::chrono::seconds(3)) == 0);
    sockaddr_in address{.sin_family = AF_INET, .sin_port = htons(port)};
    assert(::inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1);
    assert(::connect(fd, reinterpret_cast<sockaddr*>(&address),
                     sizeof(address)) == 0);
    Send("GET " + std::string(path) +
         " HTTP/1.1\r\nHost: localhost\r\nUpgrade: other,\twebsocket\r\n"
         "Connection: keep-alive,\tUpgrade\r\nSec-WebSocket-Version: "
         "13\r\nSec-WebSocket-Key: " +
         std::string(key) + "\r\nAuthorization: " + std::string(authorization) +
         "\r\n\r\n" + first);
    while (!headers.ends_with("\r\n\r\n")) {
      char c;
      Read(&c, 1);
      headers += c;
    }
  }
  ~Client() {
    ::shutdown(fd, SHUT_RDWR);
    // WINDOWS: exercise WebSocket transport on Winsock.
    gufo::platform::CloseSocket(fd);
  }
  void Send(std::string_view bytes) {
    while (!bytes.empty()) {
      // WINDOWS: exercise WebSocket transport on Winsock.
      const auto count = gufo::platform::SocketSend(fd, bytes.data(),
                                                    bytes.size(), MSG_NOSIGNAL);
      assert(count > 0);
      bytes.remove_prefix(static_cast<std::size_t>(count));
    }
  }
  static std::string Frame(std::string_view payload, unsigned opcode = 1,
                           bool final = true, bool masked = true) {
    std::string frame(1, static_cast<char>((final ? 128 : 0) | opcode));
    const unsigned mask = masked ? 128 : 0;
    if (payload.size() < 126)
      frame += static_cast<char>(mask | payload.size());
    else {
      assert(payload.size() <= 65535);
      frame += static_cast<char>(mask | 126);
      frame += static_cast<char>(payload.size() >> 8);
      frame += static_cast<char>(payload.size() & 255);
    }
    if (masked)
      frame += "abcd";
    for (std::size_t i = 0; i < payload.size(); ++i)
      frame += static_cast<char>(payload[i] ^ (masked ? "abcd"[i % 4] : 0));
    return frame;
  }
  void Text(std::string_view text) { Send(Frame(text)); }
  std::pair<unsigned, std::string> Receive() {
    std::array<unsigned char, 2> head{};
    Read(reinterpret_cast<char*>(head.data()), 2);
    assert((head[0] & 128) && !(head[1] & 128));
    std::size_t size = head[1] & 127;
    if (size >= 126) {
      const int count = size == 126 ? 2 : 8;
      size = 0;
      for (int i = 0; i < count; ++i) {
        unsigned char byte;
        Read(reinterpret_cast<char*>(&byte), 1);
        size = size * 256 + byte;
      }
    }
    assert(size < (4U << 20));
    std::string payload(size, '\0');
    Read(payload.data(), payload.size());
    return {head[0] & 15, std::move(payload)};
  }
  json::Value Event(std::string_view type) {
    auto [opcode, payload] = Receive();
    assert(opcode == 1);
    auto event = json::parse(payload);
    assert(event.member_str("type") == type);
    return event;
  }
  // WINDOWS: exercise WebSocket transport on Winsock.
  gufo::platform::SocketHandle fd;
  std::string headers;

private:
  void Read(char* bytes, std::size_t size) {
    while (size) {
      // WINDOWS: exercise WebSocket transport on Winsock.
      const auto count = gufo::platform::SocketRecv(fd, bytes, size, 0);
      assert(count > 0);
      bytes += count;
      size -= static_cast<std::size_t>(count);
    }
  }
};

// The server's receive timeout is an idle limit. A client that only listens
// to streamed output must stay connected; a silent session closes cleanly.
void ListeningClientIsNotIdle() {
// WINDOWS: exercise WebSocket transport on Winsock.
#ifdef _WIN32
  // Winsock has no POSIX socketpair; exercise the same byte stream over TCP.
  const auto listener = ::socket(AF_INET, SOCK_STREAM, 0);
  assert(listener != gufo::platform::kInvalidSocket);
  sockaddr_in address{.sin_family = AF_INET};
  assert(::inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1);
  assert(::bind(listener, reinterpret_cast<sockaddr*>(&address),
                sizeof(address)) == 0);
  assert(::listen(listener, 1) == 0);
  socklen_t length = sizeof(address);
  assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address),
                       &length) == 0);
  std::array<gufo::platform::SocketHandle, 2> fds{};
  fds[1] = ::socket(AF_INET, SOCK_STREAM, 0);
  assert(fds[1] != gufo::platform::kInvalidSocket);
  assert(::connect(fds[1], reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) == 0);
  fds[0] = ::accept(listener, nullptr, nullptr);
  assert(fds[0] != gufo::platform::kInvalidSocket);
  gufo::platform::CloseSocket(listener);
#else
  std::array<int, 2> fds{};
  assert(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds.data()) == 0);
#endif  // WINDOWS: platform coverage.
  assert(gufo::platform::SetSocketTimeout(fds[0], SO_RCVTIMEO,
                                          std::chrono::milliseconds(300)) == 0);
  assert(gufo::platform::SetSocketTimeout(fds[1], SO_RCVTIMEO,
                                          std::chrono::seconds(3)) == 0);
  {
    WebSocket socket(fds[0], {});
    // Unmasked final binary frame with a five-byte payload.
    const auto expected = std::string("\x82\x05", 2) + "audio";
    const auto streaming_until =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(1200);
    while (std::chrono::steady_clock::now() < streaming_until) {
      assert(socket.SendBinary("audio"));
      std::string frame(expected.size(), '\0');
      // WINDOWS: exercise WebSocket transport on Winsock.
      assert(gufo::platform::SocketRecv(fds[1], frame.data(), frame.size(),
                                        MSG_WAITALL) ==
             static_cast<ssize_t>(frame.size()));
      assert(frame == expected);
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    assert(!socket.cancelled());
    std::array<char, 4> close{};
    // WINDOWS: exercise WebSocket transport on Winsock.
    assert(gufo::platform::SocketRecv(fds[1], close.data(), close.size(),
                                      MSG_WAITALL) == 4);
    assert(std::string_view(close.data(), close.size()) ==
           std::string_view("\x88\x02\x03\xE9", 4));
    assert(socket.cancelled());
  }
  // WINDOWS: exercise WebSocket transport on Winsock.
  gufo::platform::CloseSocket(fds[0]);
  gufo::platform::CloseSocket(fds[1]);
}
}  // namespace

int main() {
  ListeningClientIsNotIdle();
  std::atomic<int> tts_calls{0}, asr_calls{0};
  std::atomic<bool> entered{false}, cancelled{false};
  auto tts = std::make_shared<TtsService>(TtsServiceOptions{
      .validate_model = false,
      .voices = {"vivian"},
      .runner = [&](const auto& request, const auto& check, auto* result,
                    auto*) {
        ++tts_calls;
        if (request.text == "wait") {
          entered = true;
          const auto deadline =
              std::chrono::steady_clock::now() + std::chrono::seconds(2);
          while (!check() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::yield();
          cancelled = check();
          return false;
        }
        result->sample_rate = 24000;
        result->code_groups = 16;
        result->samples = {-.5F, 0, .5F};
        if (request.on_audio)
          return request.on_audio(result->samples) &&
                 request.on_audio(result->samples);
        return true;
      }});
  auto asr = std::make_shared<AsrService>(AsrServiceOptions{
      .validate_model = false,
      .runner = [&](const auto& request, const auto&, auto* result, auto*) {
        ++asr_calls;
        assert(request.pcm16k.size() == 1600);
        assert(request.language == "en");
        result->text = "Hello world.";
        result->chunks = 1;
        return !request.on_text ||
               (request.on_text("Hello") && request.on_text(result->text));
      }});
  HttpServer server("127.0.0.1", 0, nullptr, nullptr, tts, asr,
                    {.api_key = "test"});
  std::string error;
  assert(server.start(&error));
  std::jthread worker([&] { server.run(); });
  {
    Client denied(server.port(), "/v1/realtime", {},
                  "dGhlIHNhbXBsZSBub25jZQ==", "");
    assert(denied.headers.starts_with("HTTP/1.1 401"));
    Client invalid(server.port(), "/v1/realtime", {}, "bad");
    assert(invalid.headers.starts_with("HTTP/1.1 400"));
  }
  {
    Client client(
        server.port(), "/v1/realtime?intent=transcription",
        Client::Frame(
            R"({"type":"session.update","session":{"type":"transcription","audio":{"input":{"transcription":{"model":"qwen3-asr","language":"en"},"turn_detection":null}}}})"));
    assert(client.headers.starts_with("HTTP/1.1 101"));
    assert(client.headers.find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") !=
           std::string::npos);
    assert(client.headers.find("Connection: close") == std::string::npos);
    client.Event("session.created");
    client.Event("session.updated");
    std::string previous;
    for (int turn = 0; turn < 2; ++turn) {
      const auto encoded = EncodeAudioBase64(std::string(4800, '\0'));
      client.Text(R"({"type":"input_audio_buffer.append","audio":")" + encoded +
                  "\"}");
      client.Text(R"({"type":"input_audio_buffer.commit"})");
      const auto committed = client.Event("input_audio_buffer.committed");
      assert(committed.member_str("previous_item_id") == previous);
      previous = committed.member_str("item_id");
      client.Event("conversation.item.created");
      assert(client.Event("conversation.item.input_audio_transcription.delta")
                 .member_str("delta") == "Hello");
      assert(client.Event("conversation.item.input_audio_transcription.delta")
                 .member_str("delta") == " world.");
      assert(
          client.Event("conversation.item.input_audio_transcription.completed")
              .member_str("transcript") == "Hello world.");
    }
    client.Text(
        R"({"type":"session.update","session":{"audio":{"input":{"turn_detection":{"type":"server_vad"}}}}})");
    client.Event("error");
    client.Text(R"({"type":"input_audio_buffer.commit"})");
    client.Event("error");
    assert(asr_calls == 2);
  }
  {
    Client client(server.port(), "/v1/audio/speech/stream");
    client.Text(
        R"({"type":"session.config","voice":"vivian","response_format":"pcm","stream_audio":true,"split_granularity":"sentence"})");
    const std::string message = R"({"type":"input.text","text":"Hello é. "})";
    const auto split = message.find("é") + 1;
    client.Send(
        Client::Frame(std::string_view(message).substr(0, split), 1, false));
    client.Send(Client::Frame("ping", 9));
    assert(client.Receive() == std::make_pair(10U, std::string("ping")));
    client.Send(Client::Frame(std::string_view(message).substr(split), 0));
    assert(client.Event("audio.start").member_str("sentence_text") ==
           "Hello é.");
    const auto expected = EncodePcm16(std::vector<float>{-.5F, 0, .5F});
    assert(client.Receive() == std::make_pair(2U, expected));
    assert(client.Receive() == std::make_pair(2U, expected));
    client.Event("audio.done");
    client.Text(R"({"type":"input.done"})");
    client.Event("session.done");
    client.Text(
        R"({"type":"session.config","voice":"vivian","response_format":"pcm","stream_audio":true})");
    client.Text(R"({"type":"input.text","text":"Next utterance"})");
    client.Text(R"({"type":"input.done"})");
    client.Event("audio.start");
    client.Receive();
    client.Receive();
    client.Event("audio.done");
    client.Event("session.done");
    assert(tts_calls == 2);
    client.Send(Client::Frame("unmasked", 1, true, false));
    // WINDOWS: An unread payload must not reset away the protocol-error close
    // reply before a slow peer has a chance to consume it.
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    auto [opcode, close] = client.Receive();
    assert(opcode == 8 && close == std::string("\x03\xEA", 2));
  }
  {
    Client client(server.port(), "/v1/audio/speech/stream");
    client.Text(
        R"({"type":"session.config","voice":"vivian","response_format":"pcm","stream_audio":true})");
    client.Text(R"({"type":"input.text","text":"wait"})");
    client.Text(R"({"type":"input.done"})");
    client.Event("audio.start");
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!entered && std::chrono::steady_clock::now() < deadline)
      std::this_thread::yield();
    assert(entered);
    client.Send(Client::Frame(std::string("\x03\xE8", 2), 8));
    assert(client.Receive().first == 8);
    while (!cancelled && std::chrono::steady_clock::now() < deadline)
      std::this_thread::yield();
    assert(cancelled);
  }
  // Exercise closure before/while the consumer waits for its first message.
  // Every connection must release its worker and admission slot.
  for (int i = 0; i < 32; ++i) {
    Client client(server.port(), "/v1/audio/speech/stream");
    client.Send(Client::Frame(std::string("\x03\xE8", 2), 8));
    const auto reply = client.Receive();
    assert(reply.first == 8 && reply.second == std::string("\x03\xE8", 2));
  }
  // WINDOWS: A local stop must wake readers even when no WebSocket frame
  // arrives.
  {
    HttpServer idle_server("127.0.0.1", 0, nullptr, nullptr, tts, asr,
                           {.api_key = "test"});
    assert(idle_server.start(&error));
    std::jthread idle_worker([&] { idle_server.run(); });
    Client idle(idle_server.port(), "/v1/audio/speech/stream");
    // Leave a masked frame incomplete as well as the application session.
    idle.Send(std::string("\x81\x85", 2));
    const auto start = std::chrono::steady_clock::now();
    idle_server.stop();
    idle_worker.join();
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
  }
  // Stop also cancels active work while the reader is waiting for more input.
  {
    entered = false;
    cancelled = false;
    Client active(server.port(), "/v1/audio/speech/stream");
    active.Text(
        R"({"type":"session.config","voice":"vivian","response_format":"pcm","stream_audio":true})");
    active.Text(R"({"type":"input.text","text":"wait"})");
    active.Text(R"({"type":"input.done"})");
    active.Event("audio.start");
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!entered && std::chrono::steady_clock::now() < deadline)
      std::this_thread::yield();
    assert(entered);
    server.stop();
    assert(cancelled);
    assert(std::chrono::steady_clock::now() < deadline);
  }
  server.stop();
  worker.join();
}
