abstract class ContactPhotoResolver {
  /// Returns the local file path of the contact's photo for the given phone
  /// [number], or null if no photo is available.
  ///
  /// The returned path must point to a file that exists on disk — it is passed
  /// directly to [BitmapFactory.decodeFile] on Android.
  Future<String?> resolvePathWithNumber(String? number);
}
