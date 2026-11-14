// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (server_manager.dart:1096,
// group_helper.dart:1342):
//   var tagGen = TagGen(tags: tagSets);   // tagSets: Map<String, int>
//   server.tag = tagGen.gen(server.tag);  // -> unique String tag

/// Generates unique outbound tags against a set of already-used tags.
/// The [tags] map (tag -> occurrence count) is updated in place.
class TagGen {
  TagGen({required this.tags});

  final Map<String, int> tags;

  /// Return [tag] if unused; otherwise append " 2", " 3", ... until the
  /// result is unique. The returned tag is registered in [tags].
  String gen(String tag) {
    if (!tags.containsKey(tag)) {
      tags[tag] = 1;
      return tag;
    }
    int count = (tags[tag] ?? 1) + 1;
    while (true) {
      final candidate = '$tag $count';
      if (!tags.containsKey(candidate)) {
        tags[tag] = count;
        tags[candidate] = 1;
        return candidate;
      }
      count++;
    }
  }
}
