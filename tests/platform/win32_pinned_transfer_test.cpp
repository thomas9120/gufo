// Native HIP checks without the Linux backing test's ELF --wrap fault hooks.
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>
#include <stdexcept>
#include <thread>
#include <vector>

#include "src/core/hip/committed_backing.hpp"
#include "src/core/hip/snapshot_transfer.hpp"
#include "src/core/hip/staging.hpp"
#include "src/core/hip/transfer_pool.hpp"

namespace cache = gufo::cache;
namespace gpu = gufo::hip;
using Category = cache::ResourceCategory;
using Result = cache::TransferResult;
namespace {
constexpr std::size_t block_bytes = 64 << 10, metadata = 16 << 10;
constexpr std::size_t budget = 3 * block_bytes + metadata;
cache::ResourceLimits Limits() {
  return {budget, budget, block_bytes, budget};
}
template<typename Exception, typename F>
void Throws(F action) {
  bool caught = false;
  try {
    action();
  } catch (const Exception&) {
    caught = true;
  }
  assert(caught);
}
void Coherent(void* address) {
  unsigned flags{};
  assert(hipHostGetFlags(&flags, address) == hipSuccess);
  assert(flags & hipHostMallocCoherent);
}
void Registered(void* address) {
  // Committed backing now registers anonymous pages; hipHostGetFlags is
  // defined for hipHostMalloc allocations, which staging still uses.
  hipPointerAttribute_t attributes{};
  assert(hipPointerGetAttributes(&attributes, address) == hipSuccess);
  assert(attributes.type == hipMemoryTypeHost);
  void* mapped{};
  assert(hipHostGetDevicePointer(&mapped, address, 0) == hipSuccess && mapped);
}
void Backing() {
  cache::ResourceLedger ledger(Limits());
  std::optional<gpu::BackingPin> survivor;
  std::byte* address{};
  {
    gpu::CommittedBackingPool pool(ledger, {budget, block_bytes, metadata});
    assert(pool.BlockCount() == 3 && pool.PageCommitAllocations() == 1);
    assert(pool.CommittedBytes() == 3 * block_bytes);
    assert(ledger.Snapshot().total_bytes == budget);
    std::array<std::optional<gpu::BackingBlock>, 3> blocks;
    std::array<std::byte*, 3> addresses;
    for (std::size_t i = 0; i < blocks.size(); ++i) {
      blocks[i] = pool.TryAcquire(Category::kPrivateTail);
      assert(blocks[i] && blocks[i]->Info().reserved);
      addresses[i] = blocks[i]->Bytes().data();
      assert(std::ranges::all_of(blocks[i]->Bytes(),
                                 [](std::byte b) { return b == std::byte{}; }));
      blocks[i]->Convert();
    }
    Registered(addresses[0]);
    assert(!pool.TryAcquire(Category::kPrivateState));
    auto pin = std::make_optional(blocks[0]->PinPersistence());
    blocks[0].reset();
    assert(!pool.TryAcquire(Category::kPrivateState));
    pin.reset();
    blocks[0] = pool.TryAcquire(Category::kPrivateState);
    assert(blocks[0] && blocks[0]->Bytes().data() == addresses[0]);
    blocks[0].reset();  // Unconverted assignment rolls back too.
    ledger.FailAfter(cache::LedgerStep::kReserve, 0);
    assert(!pool.TryAcquire(Category::kPrivateTail));
    auto block = pool.TryAcquire(Category::kPrivateTail);
    assert(block);
    ledger.FailAfter(cache::LedgerStep::kConvert, 0);
    Throws<std::bad_alloc>([&] { block->Convert(); });
    assert(block->Info().reserved);
    block->Convert();
    block.reset();
    blocks = {};
    // Independent borrowers cannot own the same physical block.
    std::atomic<unsigned> active{};
    std::vector<std::jthread> workers;
    for (int i = 0; i < 4; ++i) {
      workers.emplace_back([&] {
        for (int j = 0; j < 100; ++j) {
          auto held = pool.TryAcquire(Category::kPrivateTail);
          if (!held)
            continue;
          const auto found = std::ranges::find(addresses, held->Bytes().data());
          assert(found != addresses.end());
          const auto bit = 1U << (found - addresses.begin());
          assert(!(active.fetch_or(bit) & bit));
          held->Convert();
          assert(active.fetch_and(~bit) & bit);
        }
      });
    }
    workers.clear();
    assert(active == 0 && ledger.Snapshot().total_bytes == budget);
    block = pool.TryAcquire(Category::kPrivateState);
    assert(block);
    block->Convert();
    address = block->Bytes().data();
    survivor.emplace(block->PinPersistence());
  }
  // Pin retains both physical storage and the slab's full ledger charge.
  address[0] = std::byte{42};
  assert(ledger.Snapshot().total_bytes == budget);
  survivor.reset();
  assert(ledger.Snapshot().total_bytes == 0);
  ledger.FailAfter(cache::LedgerStep::kConvert, 2);
  Throws<std::bad_alloc>([&] {
    gpu::CommittedBackingPool pool(ledger, {budget, block_bytes, metadata});
  });
  assert(ledger.Snapshot().total_bytes == 0);
  Throws<std::invalid_argument>(
      [&] { gpu::CommittedBackingPool pool(ledger, {budget, 1, metadata}); });
}
void StagingAndCopies() {
  cache::ResourceLedger ledger(Limits());
  {
    // StreamedStore owns payload admission; the allocator admits metadata.
    auto payload = ledger.Reserve(Category::kTransferStaging, block_bytes);
    auto allocator = gpu::PinnedStagingAllocator(ledger);
    ledger.FailAfter(cache::LedgerStep::kConvert, 0);
    Throws<std::bad_alloc>([&] { (void)allocator(block_bytes); });
    assert(ledger.Snapshot().total_bytes == block_bytes);
    auto staging = allocator(block_bytes);
    auto charge = payload.Convert();
    Coherent(staging.bytes.data());
    assert(std::ranges::all_of(staging.bytes, [](auto b) { return b == 0; }));
    auto retained = staging.owner;
    staging.owner.reset();
    allocator = {};
    gpu::CommittedBackingPool backing(
        ledger, {block_bytes + metadata, block_bytes, metadata});
    auto destination = backing.TryAcquire(Category::kPrivateTail);
    assert(destination);
    void* device{};
    assert(hipMalloc(&device, block_bytes) == hipSuccess);
    gpu::TransferPool pool(2);
    auto first = pool.TryAcquire(), second = pool.TryAcquire();
    assert(first && second && first->Native() != second->Native());
    assert(!pool.TryAcquire());
    for (std::size_t i = 0; i < staging.bytes.size(); ++i)
      staging.bytes[i] = static_cast<std::uint8_t>(i * 37 + 11);
    std::ranges::fill(destination->Bytes(), std::byte{0x33});
    // Nonuniform payload, unaligned endpoints, odd pieces and a short tail.
    constexpr auto bytes = block_bytes - 3;
    {
      auto up = first->Copy(static_cast<std::byte*>(device) + 1,
                            staging.bytes.data() + 1, bytes,
                            gpu::CopyDirection::kHostToDevice, 4093);
      assert(up.Wait() == Result::kSucceeded && up.Ready());
      assert(up.Wait() == Result::kSucceeded);
      Throws<std::logic_error>([&] { (void)first->Native(); });
      auto down = second->Copy(destination->Bytes().data() + 1,
                               static_cast<std::byte*>(device) + 1, bytes,
                               gpu::CopyDirection::kDeviceToHost, 4093);
      assert(down.Wait() == Result::kSucceeded && down.Ready());
      assert(std::memcmp(destination->Bytes().data() + 1,
                         staging.bytes.data() + 1, bytes) == 0);
      for (auto index : {std::size_t{0}, block_bytes - 2, block_bytes - 1})
        assert(destination->Bytes()[index] == std::byte{0x33});
      first.reset();
      second.reset();
      assert(
          !pool.TryAcquire());  // Waited completions still retain their pairs.
    }
    for (int i = 0; i < 10; ++i) {
      auto stream = pool.TryAcquire();
      assert(stream);
      Throws<std::invalid_argument>([&] {
        (void)stream->Copy(nullptr, nullptr, 1,
                           gpu::CopyDirection::kHostToDevice, 1);
      });
      auto empty = stream->Copy(nullptr, nullptr, 0,
                                gpu::CopyDirection::kHostToDevice, 1);
      assert(empty.Wait() == Result::kSucceeded);
    }
    // Queued regions drain before borrowed-stream release, even without Finish.
    hipStream_t borrowed{};
    assert(hipStreamCreateWithFlags(&borrowed, hipStreamNonBlocking) ==
           hipSuccess);
    bool released = false;
    {
      gpu::SnapshotTransfer snapshot(borrowed, [&](hipStream_t stream) {
        assert(stream == borrowed);
        assert(std::memcmp(destination->Bytes().data(), staging.bytes.data(),
                           block_bytes) == 0);
        released = true;
      });
      snapshot.Enqueue(device, staging.bytes.data(), block_bytes,
                       hipMemcpyHostToDevice);
      snapshot.Enqueue(destination->Bytes().data(), device, block_bytes);
    }
    assert(released);
    assert(hipStreamDestroy(borrowed) == hipSuccess);
    // Different pitches must preserve padding while copying every row.
    std::ranges::fill(destination->Bytes(), std::byte{0x33});
    {
      gpu::SnapshotTransfer snapshot;
      snapshot.Copy2D(destination->Bytes().data(), 47, device, 53, 37, 11);
    }
    for (std::size_t row = 0; row < 11; ++row) {
      assert(std::memcmp(destination->Bytes().data() + row * 47,
                         staging.bytes.data() + row * 53, 37) == 0);
      for (std::size_t column = 37; column < 47; ++column)
        assert(destination->Bytes()[row * 47 + column] == std::byte{0x33});
    }
    assert(hipFree(device) == hipSuccess);
  }
  assert(ledger.Snapshot().total_bytes == 0);
}
void PendingAndLifetime() {
  std::optional<cache::Completion> survivor;
  {
    gpu::TransferPool pool(2);
    auto blocked = pool.TryAcquire(), peer = pool.TryAcquire();
    std::atomic<bool> release{};
    assert(hipLaunchHostFunc(
               blocked->Native(),
               [](void* data) {
                 auto& gate = *static_cast<std::atomic<bool>*>(data);
                 while (!gate.load())
                   std::this_thread::yield();
               },
               &release) == hipSuccess);
    auto pending = blocked->Complete();
    assert(!pending.Ready());
    auto ready = peer->Complete();
    assert(ready.Wait() == Result::kSucceeded);
    assert(!pending.Ready() && !pool.TryAcquire());
    release = true;
    assert(pending.Wait() == Result::kSucceeded);
    survivor.emplace(std::move(pending));
  }
  assert(survivor->Wait() == Result::kSucceeded && survivor->Ready());
  survivor.reset();
}
void BoundStreamLifetime() {
  std::optional<cache::Completion> completion;
  std::weak_ptr<void> retained;
  std::array<std::uint8_t, 257> source{}, copied{};
  for (std::size_t i = 0; i < source.size(); ++i)
    source[i] = static_cast<std::uint8_t>(i * 37 + 11);
  void* device{};
  assert(hipMalloc(&device, source.size()) == hipSuccess);
  {
    hipStream_t native{};
    assert(hipStreamCreateWithFlags(&native, hipStreamNonBlocking) ==
           hipSuccess);
    auto owner = std::shared_ptr<void>(native, [](void* stream) {
      assert(hipStreamDestroy(static_cast<hipStream_t>(stream)) == hipSuccess);
    });
    retained = owner;
    gpu::TransferPool pool(1);
    auto stream = pool.TryAcquire();
    Throws<std::invalid_argument>([&] { stream->BindTo(nullptr, owner); });
    Throws<std::invalid_argument>([&] { stream->BindTo(native, {}); });
    stream->BindTo(native, owner);
    owner.reset();
    assert(stream->Native() == native);
    Throws<std::logic_error>([&] { stream->BindTo(native, retained.lock()); });
    completion.emplace(stream->Copy(device, source.data(), source.size(),
                                    gpu::CopyDirection::kHostToDevice, 37));
    assert(completion->Wait() == Result::kSucceeded);
    assert(hipMemcpy(copied.data(), device, copied.size(),
                     hipMemcpyDeviceToHost) == hipSuccess);
    assert(source == copied);
    stream.reset();
    assert(!retained.expired() && !pool.TryAcquire());
  }
  assert(!retained.expired());
  assert(completion->Wait() == Result::kSucceeded && completion->Ready());
  completion.reset();
  assert(retained.expired());
  assert(hipFree(device) == hipSuccess);
}
}  // namespace
int main() {
  hipDeviceProp_t device{};
  assert(hipGetDeviceProperties(&device, 0) == hipSuccess);
  assert(std::strncmp(device.gcnArchName, "gfx1151", 7) == 0);
  Backing();
  StagingAndCopies();
  PendingAndLifetime();
  BoundStreamLifetime();
  std::puts(
      "PASS: coherent backing/staging, accounting and pins, concurrent "
      "borrowers, bounded copies, pitched snapshots and stream lifetimes");
}
