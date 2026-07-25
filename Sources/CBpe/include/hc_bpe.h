// C entry point for the BPE encoder that sherpa-onnx itself uses to turn keyword
// text into model tokens. The implementation (ssentencepiece) is already inside
// the sherpa-onnx static library we link, so this only bridges it to Swift.
#ifndef HC_BPE_H_
#define HC_BPE_H_

#ifdef __cplusplus
extern "C" {
#endif

// Encodes `text` into space-separated sentencepiece tokens using the vocabulary
// at `vocab_path`. Returns a malloc'd C string the caller must free with
// hc_bpe_free, or NULL if the vocabulary cannot be loaded.
char *hc_bpe_encode(const char *vocab_path, const char *text);

void hc_bpe_free(char *tokens);

#ifdef __cplusplus
}
#endif

#endif  // HC_BPE_H_
