import '../../../l10n/app_localizations.dart';

/// Every title that means "nothing has named this conversation yet", in every
/// language the app ships.
///
/// A conversation keeps the title it was created with, and the user can switch
/// language at any time without restarting. Asking "is this the placeholder of
/// the *current* language?" is therefore wrong in both directions: a chat
/// created before an EN→ZH switch would never be auto-named, and one titled in
/// EN would be renamed while the UI is ZH. The property that actually holds is
/// "the title is some known placeholder", so the naming path checks against this
/// set instead of a single captured string.
Set<String> localizedPlaceholderTitles() => <String>{
  for (final locale in AppLocalizations.supportedLocales) ...[
    lookupAppLocalizations(locale).titleForLocale,
    lookupAppLocalizations(locale).groupChatNewTopic,
  ],
};
