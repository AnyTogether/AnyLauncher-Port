part of 'together_model.dart';

/// Social steps that cannot be taken back ask first, in place, as on the Mac: pressing the row
/// turns it into the question, the step itself and Cancel, with Cancel focused, so a pad's confirm
/// button pressed twice by habit never removes someone or leaves a party. Back answers Cancel.
extension TogetherAsk on TogetherModel {
  /// [row] as it shows: itself, asking first when pressed, or the question while it asks.
  List<PanelRow> askingFirst(PanelRow row, String question) {
    final kind = row.kind;
    if (kind is! ActionRow) return [row];
    if (askingRow != row.id) {
      return [
        PanelRow(
          id: row.id,
          title: row.title,
          detail: row.detail,
          person: row.person,
          kind: ActionRow(() => ask(row.id), destructive: true),
        ),
      ];
    }
    return [
      PanelRow(id: '${row.id}-ask', title: question, kind: const InfoRow('')),
      PanelRow(
        id: '${row.id}-yes',
        title: row.title,
        kind: ActionRow(() {
          askingRow = null;
          kind.run();
        }, destructive: true),
      ),
      PanelRow(id: '${row.id}-cancel', title: T.text('cancel'), kind: ActionRow(cancelAsk)),
    ];
  }

  /// The question comes in place of the row, Cancel focused.
  void ask(String id) {
    askingRow = id;
    _focusRow('$id-cancel');
  }

  /// Cancel or Back: the row again, focused. False when nothing was asking.
  bool cancelAsk() {
    final id = askingRow;
    if (id == null) return false;
    askingRow = null;
    app.sounds.play(Cue.back);
    _focusRow(id);
    return true;
  }

  void _focusRow(String id) {
    final categories = app.panelCategories();
    if (categories.isNotEmpty) {
      final rows = categories[app.panelCategory.clamp(0, categories.length - 1)].rows;
      final index = rows.indexWhere((row) => row.id == id);
      if (index >= 0) app.panelRow = index;
    }
    app.refresh();
  }
}
