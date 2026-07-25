#include "hc_bpe.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "ssentencepiece/csrc/ssentencepiece.h"

namespace {

// Building the encoder parses the whole vocabulary, so keep one per file. The
// enrollment UI encodes a phrase on every keystroke-driven check.
std::unordered_map<std::string, std::shared_ptr<ssentencepiece::Ssentencepiece>> g_cache;
std::mutex g_mutex;

std::shared_ptr<ssentencepiece::Ssentencepiece> Load(const std::string &path) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_cache.find(path);
  if (it != g_cache.end()) return it->second;
  std::shared_ptr<ssentencepiece::Ssentencepiece> processor;
  try {
    // One thread: these are single short phrases, and a thread pool per call
    // would cost more than the work itself.
    processor = std::make_shared<ssentencepiece::Ssentencepiece>(path, 1);
  } catch (...) {
    return nullptr;
  }
  g_cache[path] = processor;
  return processor;
}

}  // namespace

char *hc_bpe_encode(const char *vocab_path, const char *text) {
  if (vocab_path == nullptr || text == nullptr) return nullptr;
  auto processor = Load(vocab_path);
  if (processor == nullptr) return nullptr;

  std::vector<std::string> pieces;
  try {
    processor->Encode(text, &pieces);
  } catch (...) {
    return nullptr;
  }
  if (pieces.empty()) return nullptr;

  std::string joined;
  for (size_t i = 0; i < pieces.size(); ++i) {
    if (i > 0) joined += " ";
    joined += pieces[i];
  }
  char *out = static_cast<char *>(std::malloc(joined.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, joined.c_str(), joined.size() + 1);
  return out;
}

void hc_bpe_free(char *tokens) { std::free(tokens); }
