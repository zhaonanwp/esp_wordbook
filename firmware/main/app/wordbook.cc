#include "wordbook.h"

#include <cstdio>
#include <cstring>

#include "esp_log.h"

static const char* TAG = "Wordbook";

// 词表文件上限。按每周 25 词、一年 1000 词、每行 ~120 字节算，512KB 余量足够。
static constexpr size_t kMaxFileBytes = 512 * 1024;

namespace {

char* Trim(char* s) {
    while (*s == ' ' || *s == '\t') {
        s++;
    }
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\r')) {
        s[--len] = '\0';
    }
    return s;
}

}  // namespace

bool Wordbook::Load(const char* path, std::string* err) {
    entries_.clear();
    buffer_.clear();

    FILE* fp = fopen(path, "rb");
    if (fp == nullptr) {
        if (err) {
            *err = std::string("打不开 ") + path + "（词表还没烧进 storage 分区？）";
        }
        return false;
    }

    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0) {
        fclose(fp);
        if (err) {
            *err = std::string(path) + " 是空的";
        }
        return false;
    }
    if (static_cast<size_t>(size) > kMaxFileBytes) {
        fclose(fp);
        if (err) {
            *err = std::string(path) + " 超过 " + std::to_string(kMaxFileBytes / 1024) + "KB 上限";
        }
        return false;
    }

    buffer_.resize(static_cast<size_t>(size) + 1);
    size_t read = fread(buffer_.data(), 1, static_cast<size_t>(size), fp);
    fclose(fp);
    buffer_[read] = '\0';

    char* base = buffer_.data();

    auto parse_line = [&](char* line) {
        char* fields[4] = {line, const_cast<char*>(""), const_cast<char*>(""), const_cast<char*>("")};
        int field = 0;
        for (char* p = line; *p != '\0'; p++) {
            if (*p == '\t' && field < 3) {
                *p = '\0';
                fields[++field] = p + 1;
            }
        }
        for (int i = 0; i < 4; i++) {
            fields[i] = Trim(fields[i]);
        }
        if (*fields[0] != '\0' && fields[0][0] != '#') {
            entries_.push_back(WordEntry{fields[0], fields[1], fields[2], fields[3]});
        }
    };

    // 逐行切：'\n' 就地改成 '\0'，行内再按 '\t' 切字段。最后一行可能没有换行符。
    char* line = base;
    for (size_t i = 0; i < read; i++) {
        if (base[i] != '\n') {
            continue;
        }
        base[i] = '\0';
        parse_line(line);
        line = base + i + 1;
    }
    if (*line != '\0') {
        parse_line(line);
    }

    if (entries_.empty()) {
        if (err) {
            *err = std::string(path) + " 里没有有效词条";
        }
        return false;
    }

    ESP_LOGI(TAG, "词表 %s 载入 %u 条, %ld 字节", path,
             static_cast<unsigned>(entries_.size()), size);
    return true;
}
