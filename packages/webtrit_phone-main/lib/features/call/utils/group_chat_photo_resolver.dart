abstract class GroupChatPhotoResolver {
  /// Returns the local file path of the group chat's photo for the given
  /// [chatId], or null if no photo is available.
  ///
  /// The returned path must point to a file that exists on disk — it is passed
  /// directly to [BitmapFactory.decodeFile] on Android.
  Future<String?> resolvePathWithChatId(String? chatId);
}
