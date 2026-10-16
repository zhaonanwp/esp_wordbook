#ifndef _WORDCARD_STORAGE_H_
#define _WORDCARD_STORAGE_H_

#include <string>

// storage 分区（FAT + wear_levelling）挂载点。
// 词表和复习状态都落在这里，设备侧只认这个目录下的文件，
// 不关心文件是 PC 烧进来的还是以后从服务器拉下来的。
namespace storage {

constexpr const char* kMountPoint = "/wordbook";

// 挂载 storage 分区。已挂载时直接返回 true。
bool Mount();

bool IsMounted();

std::string Path(const char* name);

}  // namespace storage

#endif
