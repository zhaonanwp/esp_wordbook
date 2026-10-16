#ifndef _WORDCARD_WORDBOOK_H_
#define _WORDCARD_WORDBOOK_H_

#include <cstddef>
#include <string>
#include <vector>

// 一条词条。四个字段都指向内部缓冲区，随 Wordbook 生命周期有效。
struct WordEntry {
    const char* word = "";
    const char* phonetic = "";
    const char* meaning = "";
    const char* example = "";
};

// 词表：storage 分区里的一个 TSV 文本文件，一行一词，字段用 Tab 分隔
//   单词<TAB>音标<TAB>中文释义<TAB>例句
// '#' 开头的行和空行忽略，后面缺的字段留空。
class Wordbook {
public:
    // 成功返回 true；文件不存在/为空/超过大小上限时返回 false 并填 err。
    bool Load(const char* path, std::string* err);

    size_t Count() const { return entries_.size(); }
    const WordEntry& At(size_t index) const { return entries_[index]; }

private:
    std::vector<char> buffer_;              // 整个文件的原始内容
    std::vector<WordEntry> entries_;
};

#endif
