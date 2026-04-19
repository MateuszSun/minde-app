import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gra/main.dart';

String _todayKey() {
  final now = DateTime.now();
  final year = now.year.toString().padLeft(4, '0');
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders flow home and opens flow runner details', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    expect(find.text('Minde'), findsOneWidget);
    final splitDecisionFinder = find.byKey(
      const ValueKey<String>('exercise-splitDecision'),
    );
    await tester.scrollUntilVisible(splitDecisionFinder, 300);
    await tester.ensureVisible(splitDecisionFinder);
    await tester.pumpAndSettle();
    expect(splitDecisionFinder, findsOneWidget);

    final cardFinder = find.byKey(
      const ValueKey<String>('exercise-flowRunner'),
    );
    await tester.scrollUntilVisible(cardFinder, 300);
    await tester.ensureVisible(cardFinder);
    await tester.pumpAndSettle();
    expect(cardFinder, findsOneWidget);

    await tester.tap(
      find.descendant(
        of: cardFinder,
        matching: find.widgetWithText(FilledButton, 'Otwórz'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ExerciseDetailPage), findsOneWidget);
    expect(find.text('Flow Runner'), findsOneWidget);
  });

  testWidgets('minde shield icon opens ideas page and saves note', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    final ideasButton = find.byKey(const ValueKey<String>('minde-ideas-open'));
    expect(ideasButton, findsOneWidget);

    await tester.tap(ideasButton);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Nootatki'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('minde-ideas-category-toggle')),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    const categoryName = 'Pomysły';
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-category-input')),
      categoryName,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('minde-category-add')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(categoryName), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('minde-note-create')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Notatka'), findsOneWidget);

    const noteTopic = 'Poranny rytuał';
    const noteContent =
        'Pomysł na własny rytuał skupienia po porannym alarmie.';
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-note-topic-input')),
      noteTopic,
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-note-content-input')),
      noteContent,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('minde-note-save')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(noteTopic), findsOneWidget);
    expect(find.text(noteContent), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    final rawNotes = preferences.getString('minde_ideas_notes_v1');
    expect(rawNotes, isNotNull);

    final decodedSnapshot = Map<String, dynamic>.from(
      jsonDecode(rawNotes!) as Map<dynamic, dynamic>,
    );
    final decodedNotes = decodedSnapshot['notes'] as List<dynamic>;
    final decodedCategories = decodedSnapshot['categories'] as List<dynamic>;
    expect(decodedNotes, isNotEmpty);
    final latestNote = Map<String, dynamic>.from(
      decodedNotes.first as Map<dynamic, dynamic>,
    );
    final latestCategory = Map<String, dynamic>.from(
      decodedCategories.first as Map<dynamic, dynamic>,
    );
    expect(latestCategory['name'], categoryName);
    expect(latestNote['topic'], noteTopic);
    expect(latestNote['content'], noteContent);
  });

  testWidgets('minde category box supports rename and delete on long press', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    await tester.tap(find.byKey(const ValueKey<String>('minde-ideas-open')));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('minde-ideas-category-toggle')),
    );
    await tester.pumpAndSettle();

    const categoryName = 'Szybkie pomysły';
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-category-input')),
      categoryName,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('minde-category-add')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('minde-note-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-note-topic-input')),
      'Temat',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-note-content-input')),
      'Treść notatki',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('minde-note-save')));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    final rawBeforeRename = preferences.getString('minde_ideas_notes_v1');
    expect(rawBeforeRename, isNotNull);
    final snapshotBeforeRename = Map<String, dynamic>.from(
      jsonDecode(rawBeforeRename!) as Map<dynamic, dynamic>,
    );
    final categoryId =
        Map<String, dynamic>.from(
              (snapshotBeforeRename['categories'] as List<dynamic>).first
                  as Map<dynamic, dynamic>,
            )['id']
            as String;

    await tester.longPress(
      find.byKey(ValueKey<String>('minde-category-$categoryId')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('minde-category-action-edit')),
    );
    await tester.pumpAndSettle();

    const renamedCategory = 'Najlepsze pomysły';
    await tester.enterText(
      find.byKey(const ValueKey<String>('minde-category-edit-input')),
      renamedCategory,
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('minde-category-edit-save')),
    );
    await tester.pumpAndSettle();

    expect(find.text(renamedCategory), findsWidgets);
    expect(find.text(categoryName), findsNothing);

    await tester.longPress(
      find.byKey(ValueKey<String>('minde-category-$categoryId')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('minde-category-action-delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('minde-category-delete-confirm')),
    );
    await tester.pumpAndSettle();

    expect(find.text(renamedCategory), findsNothing);
    expect(find.text('Temat'), findsNothing);

    final rawAfterDelete = preferences.getString('minde_ideas_notes_v1');
    expect(rawAfterDelete, isNotNull);
    final snapshotAfterDelete = Map<String, dynamic>.from(
      jsonDecode(rawAfterDelete!) as Map<dynamic, dynamic>,
    );
    expect(snapshotAfterDelete['categories'], isEmpty);
    expect(snapshotAfterDelete['notes'], isEmpty);
  });

  testWidgets('minde category box supports reordering on long press', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    await tester.tap(find.byKey(const ValueKey<String>('minde-ideas-open')));
    await tester.pump();
    await tester.pumpAndSettle();

    Future<void> addCategory(String name) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('minde-ideas-category-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('minde-category-input')),
        name,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('minde-category-add')),
      );
      await tester.pumpAndSettle();
    }

    await addCategory('Pierwsza');
    await addCategory('Druga');

    final preferences = await SharedPreferences.getInstance();

    List<Map<String, dynamic>> readStoredCategories() {
      final rawSnapshot = preferences.getString('minde_ideas_notes_v1');
      expect(rawSnapshot, isNotNull);
      final decodedSnapshot = Map<String, dynamic>.from(
        jsonDecode(rawSnapshot!) as Map<dynamic, dynamic>,
      );
      return (decodedSnapshot['categories'] as List<dynamic>)
          .map(
            (dynamic item) =>
                Map<String, dynamic>.from(item as Map<dynamic, dynamic>),
          )
          .toList();
    }

    final categoriesBeforeMove = readStoredCategories();
    expect(
      categoriesBeforeMove
          .map((Map<String, dynamic> category) => category['name'])
          .toList(),
      <String>['Pierwsza', 'Druga'],
    );

    final firstCategoryId = categoriesBeforeMove.first['id'] as String;
    final secondCategoryId = categoriesBeforeMove.last['id'] as String;

    await tester.longPress(
      find.byKey(ValueKey<String>('minde-category-$secondCategoryId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('minde-category-action-move-up')),
    );
    await tester.pumpAndSettle();

    final categoriesAfterMoveUp = readStoredCategories();
    expect(
      categoriesAfterMoveUp
          .map((Map<String, dynamic> category) => category['name'])
          .toList(),
      <String>['Druga', 'Pierwsza'],
    );

    await tester.longPress(
      find.byKey(ValueKey<String>('minde-category-$secondCategoryId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('minde-category-action-move-down')),
    );
    await tester.pumpAndSettle();

    final categoriesAfterMoveDown = readStoredCategories();
    expect(
      categoriesAfterMoveDown
          .map((Map<String, dynamic> category) => category['name'])
          .toList(),
      <String>['Pierwsza', 'Druga'],
    );
    expect(categoriesAfterMoveDown.first['id'], firstCategoryId);
    expect(categoriesAfterMoveDown.last['id'], secondCategoryId);
  });

  testWidgets('mini games footer shows golden crown card instead of disclaimer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    final crownCard = find.byKey(const ValueKey<String>('golden-crown-card'));
    await tester.scrollUntilVisible(crownCard, 300);
    await tester.ensureVisible(crownCard);
    await tester.pumpAndSettle();

    expect(crownCard, findsOneWidget);
    expect(
      find.text(
        'To są krótkie praktyki rozwojowe pod codzienny trening uwagi. Traktuj je jako wsparcie rutyny, nie jako obietnicę efektu medycznego.',
      ),
      findsNothing,
    );
  });

  testWidgets('golden crown card unlocks secret scaffold after 20 taps', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    final crownCard = find.byKey(const ValueKey<String>('golden-crown-card'));
    await tester.scrollUntilVisible(crownCard, 300);
    await tester.ensureVisible(crownCard);
    await tester.pumpAndSettle();

    for (var tapIndex = 0; tapIndex < 20; tapIndex += 1) {
      await tester.tap(crownCard);
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      find.byKey(const ValueKey<String>('golden-secret-paper')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('golden-secret-scaffold')),
      findsOneWidget,
    );
    expect(find.text('Ta gra jest z myślą o tobie'), findsOneWidget);
    expect(find.text('Jesteś Najlepszy'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('golden-secret-scaffold')),
      findsNothing,
    );
    expect(find.text('Minde'), findsOneWidget);

    final crownCardAfter = find.byKey(
      const ValueKey<String>('golden-crown-card'),
    );
    await tester.scrollUntilVisible(crownCardAfter, 300);
    await tester.ensureVisible(crownCardAfter);
    await tester.pumpAndSettle();
    expect(crownCardAfter, findsOneWidget);
  });

  testWidgets('training card walks through 3 daily workout checkoffs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    expect(
      find.byKey(const ValueKey<String>('training-daily-card-front')),
      findsOneWidget,
    );
    expect(find.text('Trening'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('training-daily-card-front')),
        matching: find.text('0/3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('training-daily-card-front')),
        matching: find.text('3 odhaczenia dzisiaj'),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('training-daily-card-front')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey<String>('training-daily-card-back')),
      findsOneWidget,
    );
    expect(find.text('50x Pompek'), findsOneWidget);
    expect(find.text('50x Kółko'), findsOneWidget);
    expect(find.text('1/3'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('training-progress-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Ukończono'), findsOneWidget);
    expect(find.text('Kontynuować?'), findsOneWidget);
    expect(find.text('1/3'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('training-progress-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('50x Pompek'), findsOneWidget);
    expect(find.text('50x Kółko'), findsOneWidget);
    expect(find.text('2/3'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('training-progress-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Ukończono'), findsOneWidget);
    expect(find.text('2/3'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('training-progress-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('50x Pompek'), findsOneWidget);
    expect(find.text('50x Kółko'), findsOneWidget);
    expect(find.text('3/3'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('training-progress-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Trening Ukończono'), findsOneWidget);
    expect(find.text('3/3'), findsWidgets);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('training_daily_completed_date_v1'),
      equals(_todayKey()),
    );
    expect(preferences.getInt('training_daily_completed_count_v1'), equals(3));
  });

  testWidgets('training card long press can cancel or confirm reset', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    await tester.tap(
      find.byKey(const ValueKey<String>('training-daily-card-front')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(
      find.byKey(const ValueKey<String>('training-progress-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Ukończono'), findsOneWidget);
    expect(find.text('1/3'), findsWidgets);

    await tester.longPress(
      find.byKey(const ValueKey<String>('training-daily-card-back')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Czy zrestartować?'), findsOneWidget);
    expect(find.text('To wyzeruje progres treningu do 0/3.'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Nie'));
    await tester.pumpAndSettle();

    expect(find.text('Ukończono'), findsOneWidget);
    expect(find.text('1/3'), findsWidgets);

    await tester.longPress(
      find.byKey(const ValueKey<String>('training-daily-card-back')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Tak'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('training-daily-card-front')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('training-daily-card-front')),
        matching: find.text('0/3'),
      ),
      findsOneWidget,
    );

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('training_daily_completed_date_v1'), isNull);
    expect(preferences.getInt('training_daily_completed_count_v1'), isNull);
  });

  testWidgets('mnemonic morning card flips and stores today completion', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
        matching: find.text('Energiczna'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
        matching: find.text('Pamięć'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
        matching: find.text('0/3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
        matching: find.text('Po przebudzeniu'),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-back')),
      findsOneWidget,
    );
    final pendingLabel = tester.widget<Text>(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-pending')),
    );
    expect(pendingLabel.data, equals('∞'));
    expect(find.text('1/3'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('mnemonic-morning-complete-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final inProgressLabel = tester.widget<Text>(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-in-progress')),
    );
    expect(inProgressLabel.data, equals('∞'));
    expect(find.text('Kontynuować?'), findsOneWidget);
    expect(find.text('1/3'), findsWidgets);
    expect(find.text('Ukończono'), findsNothing);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('mnemonic_morning_review_v1'),
      equals(_todayKey()),
    );
    expect(preferences.getInt('mnemonic_morning_review_count_v1'), equals(1));
  });

  testWidgets('mnemonic morning card loads persisted completion for today', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mnemonic_morning_review_v1': _todayKey(),
      'mnemonic_morning_review_count_v1': 3,
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final completedLabel = tester.widget<Text>(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-completed')),
    );
    expect(completedLabel.data, equals('∞'));
    expect(find.text('Ukończono'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-back')),
        matching: find.text('3/3'),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-back')),
        matching: find.byIcon(Icons.workspace_premium_rounded),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
      findsNothing,
    );
  });

  testWidgets('mnemonic morning card resets when saved date is stale', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mnemonic_morning_review_v1': '2020-01-01',
      'mnemonic_morning_review_count_v1': 2,
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
        matching: find.text('0/3'),
      ),
      findsOneWidget,
    );
    expect(find.text('Ukończono'), findsNothing);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('mnemonic_morning_review_v1'), isNull);
    expect(preferences.getInt('mnemonic_morning_review_count_v1'), isNull);
  });

  testWidgets('mnemonic morning card long press can cancel or confirm reset', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mnemonic_morning_review_v1': _todayKey(),
      'mnemonic_morning_review_count_v1': 3,
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.longPress(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-back')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Czy wyzerować progres?'), findsOneWidget);
    expect(find.text('To cofnie box ∞ do stanu początkowego.'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Nie'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-back')),
      findsOneWidget,
    );

    await tester.longPress(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-back')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Tak'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mnemonic-morning-card-front')),
      findsOneWidget,
    );

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('mnemonic_morning_review_v1'), isNull);
    expect(preferences.getInt('mnemonic_morning_review_count_v1'), isNull);
  });

  testWidgets(
    'vibration card tracks first daily completion and stores progress',
    (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp(showLaunchExperience: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey<String>('straw-daily-card-front')),
        findsOneWidget,
      );
      expect(find.text('Wibracja'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('straw-daily-card-front')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey<String>('straw-daily-card-back')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('straw-progress-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Ukończono'), findsOneWidget);
      expect(find.text('Kontynuować?'), findsOneWidget);
      expect(find.text('1/3'), findsWidgets);

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('straw_daily_completed_date_v1'),
        equals(_todayKey()),
      );
      expect(preferences.getInt('straw_daily_completed_count_v1'), equals(1));
    },
  );

  testWidgets('vibration card loads persisted daily progress', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'straw_daily_completed_date_v1': _todayKey(),
      'straw_daily_completed_count_v1': 2,
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('straw-daily-card-front')),
      findsNothing,
    );
    expect(find.text('15min'), findsOneWidget);
    expect(find.text('3/3'), findsWidgets);
  });

  testWidgets(
    'vibration card shows completed state when daily target is complete',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'straw_daily_completed_date_v1': _todayKey(),
        'straw_daily_completed_count_v1': 3,
      });

      await tester.pumpWidget(const MyApp(showLaunchExperience: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Wibracja'), findsWidgets);
      expect(find.text('3/3'), findsWidgets);
      expect(find.textContaining('Zostały'), findsNothing);
    },
  );

  testWidgets('mnemonic vault opens and shows stored digit associations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    final vaultFinder = find.byKey(
      const ValueKey<String>('exercise-mnemonicVault'),
    );
    await tester.scrollUntilVisible(vaultFinder, 300);
    await tester.ensureVisible(vaultFinder);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: vaultFinder,
        matching: find.widgetWithText(FilledButton, 'Otwórz'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('mnemonic-vault-digit-list-toggle')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Co znajdziesz w boxie'), findsNothing);
    expect(find.text('Jak korzystać'), findsNothing);
    expect(find.text('∞'), findsOneWidget);
    expect(find.text('jajko'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('mnemonic-vault-digit-list-toggle')),
    );
    await tester.pumpAndSettle();

    expect(find.text('jajko'), findsOneWidget);
    expect(find.text('żuraw'), findsOneWidget);
    expect(find.text('Fiona'), findsOneWidget);
    expect(find.text('00'), findsNothing);
  });

  testWidgets('mnemonic vault fullscreen shows only the game', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    final vaultFinder = find.byKey(
      const ValueKey<String>('exercise-mnemonicVault'),
    );
    await tester.scrollUntilVisible(vaultFinder, 300);
    await tester.ensureVisible(vaultFinder);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: vaultFinder,
        matching: find.widgetWithText(FilledButton, 'Otwórz'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('mnemonic-vault-digit-list-toggle')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('mnemonic-vault-digit-list-toggle')),
    );
    await tester.pumpAndSettle();

    final startSessionFinder = find.text('Start sesji');
    await tester.scrollUntilVisible(
      startSessionFinder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(startSessionFinder);
    await tester.pumpAndSettle();

    await tester.tap(startSessionFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FullscreenTrainerPage), findsOneWidget);
    expect(find.text('Sejf cyfr ∞'), findsNothing);
    expect(find.text('Flow'), findsNothing);
    expect(find.text('Baza skojarzeń'), findsNothing);
    expect(find.text('Gdzie się mylisz'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('mnemonic-immersive-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-immersive-controls')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-immersive-progress')),
      findsOneWidget,
    );
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mnemonic-vault-countdown-3')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('mnemonic-immersive-stop')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mnemonic-game-paused')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-vault-countdown-3')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('mnemonic-immersive-start')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('mnemonic-vault-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 4));
    expect(
      find.byKey(const ValueKey<String>('mnemonic-game-number')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-answer-yes')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-answer-no')),
      findsOneWidget,
    );
  });

  testWidgets(
    'mnemonic recall history removes header icon and auto-scrolls metric cards',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'mnemonic_vault_recall_history_v1': jsonEncode(<Map<String, Object>>[
          <String, Object>{
            'dateKey': '2026-04-05',
            'completedAtIso': '2026-04-05T09:15:00.000',
            'rounds': 3,
            'durationSeconds': 185,
            'problemDigits': <Map<String, Object>>[
              <String, Object>{'number': 12, 'misses': 2},
              <String, Object>{'number': 45, 'misses': 1},
            ],
          },
          <String, Object>{
            'dateKey': '2026-04-04',
            'completedAtIso': '2026-04-04T08:10:00.000',
            'rounds': 2,
            'problemDigits': <Map<String, Object>>[
              <String, Object>{'number': 12, 'misses': 1},
            ],
          },
        ]),
      });

      await tester.pumpWidget(const MyApp(showLaunchExperience: false));

      final vaultFinder = find.byKey(
        const ValueKey<String>('exercise-mnemonicVault'),
      );
      await tester.scrollUntilVisible(vaultFinder, 300);
      await tester.ensureVisible(vaultFinder);
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: vaultFinder,
          matching: find.widgetWithText(FilledButton, 'Otwórz'),
        ),
      );
      await tester.pumpAndSettle();

      final detailScrollView = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Zapisana historia trudnych cyfr'),
        300,
        scrollable: detailScrollView,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Zapisana historia trudnych cyfr'));
      await tester.pumpAndSettle();

      final headerFinder = find.byKey(
        const ValueKey<String>('mnemonic-recall-history-header'),
      );
      expect(headerFinder, findsOneWidget);
      expect(
        find.descendant(
          of: headerFinder,
          matching: find.byIcon(Icons.inventory_2_outlined),
        ),
        findsNothing,
      );

      final carouselFinder = find.byKey(
        const ValueKey<String>('mnemonic-recall-metric-carousel'),
      );
      expect(carouselFinder, findsOneWidget);

      final pageView = tester.widget<PageView>(
        find.descendant(of: carouselFinder, matching: find.byType(PageView)),
      );
      final controller = pageView.controller!;

      expect(
        controller.page ?? controller.initialPage.toDouble(),
        closeTo(0, 0.01),
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(controller.page, greaterThan(0.5));
      expect(
        find.text('stabilne 99/101 • czas sesji 3 min 5 s'),
        findsOneWidget,
      );
    },
  );

  testWidgets('mnemonic vault immersive tap speeds up next number', (
    WidgetTester tester,
  ) async {
    String currentImmersiveNumber() {
      final texts = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('mnemonic-game-number')),
          matching: find.byType(Text),
        ),
      );
      return texts
          .map((Text text) => text.data)
          .whereType<String>()
          .firstWhere((String value) => RegExp(r'^\d+$').hasMatch(value));
    }

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MnemonicVaultTrainer(
            accent: Colors.orange,
            autoStart: true,
            immersiveMode: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('0/101'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mnemonic-vault-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 4));

    expect(find.text('1/101'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mnemonic-game-number')),
      findsOneWidget,
    );

    final firstNumber = currentImmersiveNumber();
    expect(
      find.byKey(const ValueKey<String>('mnemonic-answer-yes')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mnemonic-answer-no')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('mnemonic-answer-yes')));
    await tester.pump();

    expect(find.text('2/101'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mnemonic-game-number')),
      findsOneWidget,
    );
    expect(currentImmersiveNumber(), isNot(firstNumber));
  });

  testWidgets(
    'mnemonic vault auto-advances after four seconds without answer',
    (WidgetTester tester) async {
      String currentImmersiveNumber() {
        final texts = tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('mnemonic-game-number')),
            matching: find.byType(Text),
          ),
        );
        return texts
            .map((Text text) => text.data)
            .whereType<String>()
            .firstWhere((String value) => RegExp(r'^\d+$').hasMatch(value));
      }

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MnemonicVaultTrainer(
              accent: Colors.orange,
              autoStart: true,
              immersiveMode: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      final firstNumber = currentImmersiveNumber();
      expect(find.text('1/101'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();

      expect(find.text('2/101'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mnemonic-game-number')),
        findsOneWidget,
      );
      expect(currentImmersiveNumber(), isNot(firstNumber));
    },
  );

  testWidgets(
    'mnemonic vault keeps mnemonic label hidden during quick recall',
    (WidgetTester tester) async {
      String currentImmersiveNumber() {
        final texts = tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('mnemonic-game-number')),
            matching: find.byType(Text),
          ),
        );
        return texts
            .map((Text text) => text.data)
            .whereType<String>()
            .firstWhere((String value) => RegExp(r'^\d+$').hasMatch(value));
      }

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MnemonicVaultTrainer(
              accent: Colors.orange,
              autoStart: true,
              immersiveMode: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      final currentNumber = currentImmersiveNumber();
      final labelKey = ValueKey<String>('mnemonic-answer-label-$currentNumber');

      expect(find.byKey(labelKey), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('mnemonic-answer-no')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('mnemonic-answer-yes')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 3000));
      await tester.pump();

      expect(find.byKey(labelKey), findsNothing);
    },
  );

  testWidgets(
    'mnemonic vault repeats only digits left without confirmation and exits after final mastery',
    (WidgetTester tester) async {
      String currentImmersiveNumber() {
        final texts = tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('mnemonic-game-number')),
            matching: find.byType(Text),
          ),
        );
        return texts
            .map((Text text) => text.data)
            .whereType<String>()
            .firstWhere((String value) => RegExp(r'^\d+$').hasMatch(value));
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) {
                            return FullscreenTrainerPage(
                              title: 'Sejf cyfr ∞',
                              accent: Colors.orange,
                              expandBody: true,
                              showHeader: false,
                              wrapChildInSurfaceCard: false,
                              contentMaxWidth: null,
                              bodyPadding: EdgeInsets.zero,
                              child: const MnemonicVaultTrainer(
                                accent: Colors.orange,
                                autoStart: true,
                                immersiveMode: true,
                                autoExitOnFinish: true,
                              ),
                            );
                          },
                        ),
                      );
                    },
                    child: const Text('Open mnemonic vault'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Open mnemonic vault'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(MnemonicVaultTrainer), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));

      String? deferredNumber;
      for (var index = 0; index < 101; index++) {
        final currentNumber = currentImmersiveNumber();

        if (index == 0) {
          deferredNumber = currentNumber;
          await tester.pump(const Duration(seconds: 4));
          await tester.pump();
        } else {
          await tester.tap(
            find.byKey(const ValueKey<String>('mnemonic-answer-yes')),
          );
        }
        await tester.pump();

        if (index < 100) {
          expect(
            find.byKey(const ValueKey<String>('mnemonic-game-number')),
            findsOneWidget,
          );
        }
      }

      expect(find.text('Utrwalanie'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mnemonic-vault-countdown-3')),
        findsWidgets,
      );

      await tester.pump(const Duration(seconds: 4));

      expect(find.text('1/1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mnemonic-game-number')),
        findsOneWidget,
      );
      expect(currentImmersiveNumber(), deferredNumber);

      await tester.tap(
        find.byKey(const ValueKey<String>('mnemonic-answer-yes')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(
        find.byKey(const ValueKey<String>('mnemonic-game-finish')),
        findsOneWidget,
      );
      expect(
        find.text('Gratulacje, pamiętasz wszystkie cyfry na pamięć!'),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(find.byType(MnemonicVaultTrainer), findsNothing);
      expect(find.text('Open mnemonic vault'), findsOneWidget);

      final preferences = await SharedPreferences.getInstance();
      final rawHistory = preferences.getString(
        'mnemonic_vault_recall_history_v1',
      );
      expect(rawHistory, isNotNull);

      final decodedHistory = jsonDecode(rawHistory!) as List<dynamic>;
      expect(decodedHistory, isNotEmpty);

      final latestRecord = Map<String, dynamic>.from(
        decodedHistory.first as Map<dynamic, dynamic>,
      );
      expect(latestRecord['durationSeconds'], isA<int>());
      expect(latestRecord['durationSeconds'] as int, greaterThan(0));
    },
  );

  testWidgets('mnemonic sprint runs through digits without pause', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MnemonicSprintSessionView(
            accent: Colors.orange,
            displayMilliseconds: 1,
            autoStart: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('mnemonic-sprint-countdown-stage')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('mnemonic-sprint-entry-0')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump();

    final sprintEntryFinder = find.byWidgetPredicate((Widget widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('mnemonic-sprint-entry-');
    });

    expect(
      find.byKey(const ValueKey<String>('mnemonic-sprint-countdown-stage')),
      findsNothing,
    );
    expect(sprintEntryFinder, findsWidgets);
    expect(find.text('Koniec sprintu'), findsNothing);
  });

  testWidgets('split decision detail shows clear game launcher', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(showLaunchExperience: false));

    final splitDecisionFinder = find.byKey(
      const ValueKey<String>('exercise-splitDecision'),
    );
    await tester.scrollUntilVisible(splitDecisionFinder, 300);
    await tester.ensureVisible(splitDecisionFinder);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: splitDecisionFinder,
        matching: find.widgetWithText(FilledButton, 'Otwórz'),
      ),
    );
    await tester.pumpAndSettle();

    final detailScrollView = find
        .descendant(
          of: find.byType(ExerciseDetailPage),
          matching: find.byType(Scrollable),
        )
        .first;

    await tester.drag(detailScrollView, const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.drag(detailScrollView, const Offset(0, -800));
    await tester.pumpAndSettle();

    final startGameButton = find.text('Start sesji');
    expect(find.byType(ExerciseDetailPage), findsOneWidget);
    expect(startGameButton, findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets('fullscreen split decision uses fixed non-scroll layout', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenTrainerPage(
          title: 'Split Decision',
          accent: Colors.blue,
          expandBody: true,
          child: SplitDecisionTrainer(
            accent: Colors.blue,
            immersiveLayout: true,
          ),
        ),
      ),
    );

    final fullscreenPage = find.byType(FullscreenTrainerPage);
    expect(fullscreenPage, findsOneWidget);
    expect(
      find.descendant(of: fullscreenPage, matching: find.byType(ListView)),
      findsNothing,
    );
    expect(
      find.descendant(of: fullscreenPage, matching: find.byType(SurfaceCard)),
      findsOneWidget,
    );
    expect(find.text('CZAS'), findsOneWidget);
    expect(find.text('PUNKTY'), findsOneWidget);
    expect(find.text('SKUTECZNOŚĆ'), findsNothing);
    expect(find.text('SERIA'), findsNothing);
  });

  testWidgets('split decision starts with three second countdown', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenTrainerPage(
          title: 'Split Decision',
          accent: Colors.blue,
          expandBody: true,
          child: const SplitDecisionTrainer(
            accent: Colors.blue,
            immersiveLayout: true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start sesji'));
    await tester.pump();

    expect(find.text('START ZA'), findsNothing);
    expect(find.text('Start sesji'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('split-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('split-countdown-2')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('split-countdown-1')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('split-countdown-START')),
      findsOneWidget,
    );
    final startText = tester.widget<Text>(find.text('START'));
    expect(startText.maxLines, 1);
    expect(startText.softWrap, false);
  });

  testWidgets('split decision level 4 starts with twelve second rule timer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenTrainerPage(
          title: 'Split Decision',
          accent: Colors.blue,
          expandBody: true,
          child: const SplitDecisionTrainer(
            accent: Colors.blue,
            immersiveLayout: true,
            initialLevelIndex: 3,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start sesji'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Zm. za 12 s'), findsOneWidget);
  });

  testWidgets('memory chain hides status boxes and starts with countdown', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MemoryChainTrainer(accent: Colors.orange)),
      ),
    );

    expect(find.text('Poziom'), findsNothing);
    expect(find.text('Najlepszy'), findsNothing);
    expect(find.text('Twoja kolej'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Start sesji'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Start sesji'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Start sesji'), findsNothing);
    expect(find.text('PUNKTY'), findsOneWidget);
    expect(find.text('LVL'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('memory-chain-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('memory-chain-countdown-2')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('memory-chain-countdown-1')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('memory-chain-countdown-Start')),
      findsOneWidget,
    );
    expect(find.text('Twoja kolej'), findsNothing);
  });

  testWidgets('memory chain advances automatically after a correct round', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MemoryChainTrainer(accent: Colors.orange)),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start sesji'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    final padFinder = find.byKey(const ValueKey<String>('memory-chain-pad'));
    const arrows = <IconData>[
      Icons.keyboard_arrow_up_rounded,
      Icons.keyboard_arrow_left_rounded,
      Icons.keyboard_arrow_right_rounded,
      Icons.keyboard_arrow_down_rounded,
    ];

    IconData highlightedArrow() {
      for (final iconData in arrows) {
        final icon = tester.widget<Icon>(
          find.descendant(of: padFinder, matching: find.byIcon(iconData)),
        );
        if (icon.color == Colors.white) {
          return iconData;
        }
      }
      throw StateError('No highlighted arrow found');
    }

    final sequence = <IconData>[];

    await tester.pump(const Duration(milliseconds: 400));
    sequence.add(highlightedArrow());

    await tester.pump(const Duration(milliseconds: 700));
    sequence.add(highlightedArrow());

    await tester.pump(const Duration(milliseconds: 700));
    sequence.add(highlightedArrow());

    await tester.pump(const Duration(milliseconds: 800));

    for (final iconData in sequence) {
      await tester.tap(
        find.descendant(of: padFinder, matching: find.byIcon(iconData)),
      );
      await tester.pump();
    }

    expect(
      find.byKey(const ValueKey<String>('memory-chain-feedback-ok')),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Następny poziom'), findsNothing);

    await tester.pump(const Duration(milliseconds: 2100));

    expect(
      find.byKey(const ValueKey<String>('memory-chain-pad')),
      findsOneWidget,
    );
    expect(find.text('2'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3200));
  });

  testWidgets('memory arcade switches between three memory games', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MemoryArcadeTrainer(accent: Colors.deepPurple),
          ),
        ),
      ),
    );

    expect(find.text('Ruchy'), findsOneWidget);
    expect(find.text('Kod cyfr'), findsOneWidget);
    expect(find.text('Półka słów'), findsOneWidget);
    expect(find.byType(MemoryChainTrainer), findsOneWidget);
    expect(find.text('Poziom'), findsNothing);
    expect(find.text('Najlepszy'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('memory-mode-digits')));
    await tester.pumpAndSettle();

    expect(find.byType(DigitSpanTrainer), findsOneWidget);
    expect(find.text('Kod pojawi się tylko na moment'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('memory-mode-words')));
    await tester.pumpAndSettle();

    expect(find.byType(WordShelfTrainer), findsOneWidget);
    expect(find.text('Słowa pojawią się tylko na chwilę'), findsOneWidget);
  });

  testWidgets(
    'mnemonic sequence preview wraps from six items and supports exposure slider',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MnemonicSequenceTrainer(accent: Colors.brown),
            ),
          ),
        ),
      );

      final Slider itemSlider = tester.widget<Slider>(
        find.byKey(const ValueKey<String>('mnemonic-sequence-item-slider')),
      );
      itemSlider.onChanged!(6);
      await tester.pump();

      final Slider timeSlider = tester.widget<Slider>(
        find.byKey(const ValueKey<String>('mnemonic-sequence-time-slider')),
      );
      timeSlider.onChanged!(2);
      await tester.pump();

      expect(find.text('2 s'), findsWidgets);

      final Finder previewFinder = find.byKey(
        const ValueKey<String>('mnemonic-sequence-preview'),
      );
      final Finder firstNumberFinder = find.descendant(
        of: previewFinder,
        matching: find.text('5'),
      );
      final Finder lastNumberFinder = find.descendant(
        of: previewFinder,
        matching: find.text('45'),
      );

      expect(
        tester.getTopLeft(lastNumberFinder).dy,
        greaterThan(tester.getTopLeft(firstNumberFinder).dy),
      );
    },
  );

  testWidgets(
    'mnemonic sequence session shows round header and numeric answer grid',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MnemonicSequenceSessionView(
              accent: Colors.brown,
              itemCount: 6,
              memorizeSeconds: 2,
              autoStart: true,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Runda 1/10'), findsOneWidget);
      expect(
        find.text('Zapamiętaj cały rząd, zanim cyfry znikną.'),
        findsNothing,
      );
      expect(
        find.text(
          'Patrz na cały układ i od razu buduj obrazy dla kolejnych liczb.',
        ),
        findsNothing,
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const ValueKey<String>('mnemonic-sequence-answer-grid')),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNWidgets(6));
      final TextField firstField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('mnemonic-sequence-answer-field-0')),
      );
      expect(firstField.keyboardType, TextInputType.number);
    },
  );

  testWidgets(
    'mnemonic sequence auto-advances and auto-submits on correct sequence',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MnemonicSequenceSessionView(
              accent: Colors.brown,
              itemCount: 3,
              memorizeSeconds: 1,
              autoStart: true,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 250));

      final memorizeStage = find.byKey(
        const ValueKey<String>('mnemonic-sequence-round-0'),
      );
      final List<String> sequence = tester
          .widgetList<Text>(
            find.descendant(of: memorizeStage, matching: find.byType(Text)),
          )
          .map((Text widget) => widget.data ?? '')
          .where((String text) => RegExp(r'^\d+$').hasMatch(text))
          .toList();

      expect(sequence, hasLength(3));

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));

      final firstFieldFinder = find.byKey(
        const ValueKey<String>('mnemonic-sequence-answer-field-0'),
      );
      final secondFieldFinder = find.byKey(
        const ValueKey<String>('mnemonic-sequence-answer-field-1'),
      );
      final thirdFieldFinder = find.byKey(
        const ValueKey<String>('mnemonic-sequence-answer-field-2'),
      );

      await tester.tap(firstFieldFinder);
      await tester.pump();
      await tester.enterText(firstFieldFinder, sequence[0]);
      await tester.pump();

      expect(
        tester.widget<TextField>(secondFieldFinder).focusNode!.hasFocus,
        isTrue,
      );

      await tester.enterText(secondFieldFinder, sequence[1]);
      await tester.pump();

      expect(
        tester.widget<TextField>(thirdFieldFinder).focusNode!.hasFocus,
        isTrue,
      );

      await tester.enterText(thirdFieldFinder, sequence[2]);
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('mnemonic-sequence-feedback-ok-0')),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Sprawdź'), findsNothing);
    },
  );

  testWidgets(
    'word shelf validates automatically and opens next shelf after success',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WordShelfTrainer(accent: Colors.orange)),
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Start sesji'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      final promptFinder = find.byKey(
        const ValueKey<String>('word-shelf-prompt'),
      );
      final promptTexts = tester.widgetList<Text>(
        find.descendant(of: promptFinder, matching: find.byType(Text)),
      );
      final words = promptTexts
          .map((Text widget) => widget.data)
          .whereType<String>()
          .where((String value) => value.isNotEmpty)
          .toList();

      expect(words.length, 3);

      await tester.pump(const Duration(milliseconds: 3000));

      expect(find.widgetWithText(FilledButton, 'Sprawdź półkę'), findsNothing);

      for (final word in words) {
        await tester.tap(
          find.byKey(ValueKey<String>('word-shelf-option-$word')),
        );
        await tester.pump();
      }

      expect(
        find.byKey(const ValueKey<String>('word-shelf-feedback-ok')),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Następna półka'), findsNothing);

      await tester.pump(const Duration(milliseconds: 2100));

      expect(
        find.byKey(const ValueKey<String>('word-shelf-prompt')),
        findsOneWidget,
      );
    },
  );

  testWidgets('word shelf does not repeat prompt words across rounds', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: WordShelfTrainer(accent: Colors.orange)),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start sesji'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    final promptFinder = find.byKey(
      const ValueKey<String>('word-shelf-prompt'),
    );

    List<String> promptWords() {
      return tester
          .widgetList<Text>(
            find.descendant(of: promptFinder, matching: find.byType(Text)),
          )
          .map((Text widget) => widget.data)
          .whereType<String>()
          .where((String value) => value.isNotEmpty)
          .toList();
    }

    Future<List<String>> solveCurrentRound() async {
      final words = promptWords();
      expect(words, isNotEmpty);

      await tester.pump(const Duration(milliseconds: 3000));

      for (final word in words) {
        await tester.tap(
          find.byKey(ValueKey<String>('word-shelf-option-$word')),
        );
        await tester.pump();
      }

      return words;
    }

    final firstWords = await solveCurrentRound();
    expect(firstWords.length, 3);

    await tester.pump(const Duration(milliseconds: 2100));

    final secondWords = await solveCurrentRound();
    expect(secondWords.length, 3);
    expect(secondWords.toSet().intersection(firstWords.toSet()), isEmpty);

    await tester.pump(const Duration(milliseconds: 2100));

    final thirdWords = promptWords();
    expect(thirdWords.length, 4);
    expect(
      thirdWords.toSet().intersection(<String>{...firstWords, ...secondWords}),
      isEmpty,
    );
  });

  testWidgets('digit span grows to four digits after two correct answers', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DigitSpanTrainer(accent: Colors.orange)),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start sesji'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    final firstPrompt = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('digit-span-prompt')),
        matching: find.byType(Text),
      ),
    );
    final firstDigits = firstPrompt.data!.replaceAll(' ', '');

    await tester.pump(const Duration(milliseconds: 2300));
    await tester.enterText(
      find.byKey(const ValueKey<String>('digit-span-answer-field')),
      firstDigits,
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('digit-span-feedback-ok')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 1600));

    final secondPrompt = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('digit-span-prompt')),
        matching: find.byType(Text),
      ),
    );
    final secondDigits = secondPrompt.data!.replaceAll(' ', '');

    await tester.pump(const Duration(milliseconds: 2300));
    await tester.enterText(
      find.byKey(const ValueKey<String>('digit-span-answer-field')),
      secondDigits,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('digit-span-feedback-ok')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 1600));

    final thirdPrompt = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('digit-span-prompt')),
        matching: find.byType(Text),
      ),
    );
    final thirdDigits = thirdPrompt.data!.replaceAll(' ', '');

    expect(thirdDigits.length, 4);
  });

  testWidgets(
    'digit span fullscreen ends after two mistakes and closes automatically',
    (WidgetTester tester) async {
      String wrongAnswerFor(String digits) {
        final replacementDigit = ((int.parse(digits[0]) + 1) % 10).toString();
        return List<String>.filled(digits.length, replacementDigit).join();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) {
                            return FullscreenTrainerPage(
                              title: 'Drabina Pamięci • Kod Cyfr',
                              accent: Colors.orange,
                              child: const DigitSpanTrainer(
                                accent: Colors.orange,
                                autoStart: true,
                                autoExitOnFinish: true,
                              ),
                            );
                          },
                        ),
                      );
                    },
                    child: const Text('Open digit span'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Open digit span'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DigitSpanTrainer), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));

      final firstPrompt = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('digit-span-prompt')),
          matching: find.byType(Text),
        ),
      );
      final firstDigits = firstPrompt.data!.replaceAll(' ', '');

      await tester.pump(const Duration(milliseconds: 2300));
      await tester.enterText(
        find.byKey(const ValueKey<String>('digit-span-answer-field')),
        wrongAnswerFor(firstDigits),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('digit-span-feedback-fail')),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Następny kod'));
      await tester.pump();

      final secondPrompt = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('digit-span-prompt')),
          matching: find.byType(Text),
        ),
      );
      final secondDigits = secondPrompt.data!.replaceAll(' ', '');

      await tester.pump(const Duration(milliseconds: 2300));
      await tester.enterText(
        find.byKey(const ValueKey<String>('digit-span-answer-field')),
        wrongAnswerFor(secondDigits),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('digit-span-finished')),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Start sesji'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(DigitSpanTrainer), findsNothing);
    },
  );

  testWidgets('split decision fullscreen closes automatically after finish', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) {
                          return FullscreenTrainerPage(
                            title: 'Split Decision',
                            accent: Colors.blue,
                            expandBody: true,
                            child: const SplitDecisionTrainer(
                              accent: Colors.blue,
                              immersiveLayout: true,
                              autoStart: true,
                              autoExitOnFinish: true,
                            ),
                          );
                        },
                      ),
                    );
                  },
                  child: const Text('Open split decision'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open split decision'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SplitDecisionTrainer), findsOneWidget);

    await tester.pump(const Duration(seconds: 124));

    expect(
      find.byKey(const ValueKey<String>('split-finished')),
      findsOneWidget,
    );
    expect(find.text('Najlepsze wyniki dnia'), findsNothing);
    expect(find.text('Zagraj ponownie'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(SplitDecisionTrainer), findsNothing);
  });

  testWidgets('pulse sync preview shows tempo time points and start session', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PulseSyncTrainer(accent: Colors.green, fullscreenOnStart: true),
        ),
      ),
    );

    expect(find.text('TEMPO'), findsOneWidget);
    expect(find.text('CZAS'), findsOneWidget);
    expect(find.text('PUNKTY'), findsOneWidget);
    expect(find.text('SYNC'), findsNothing);
    expect(find.text('IDEALNE'), findsNothing);
    expect(find.text('Reset'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Start sesji'), findsOneWidget);
  });

  testWidgets('pulse sync fullscreen counts down and closes after finish', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) {
                          return FullscreenTrainerPage(
                            title: 'Pulse Sync',
                            accent: Colors.green,
                            child: const PulseSyncTrainer(
                              accent: Colors.green,
                              autoStart: true,
                              autoExitOnFinish: true,
                            ),
                          );
                        },
                      ),
                    );
                  },
                  child: const Text('Open pulse sync'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open pulse sync'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(PulseSyncTrainer), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PulseSyncTrainer),
        matching: find.widgetWithText(FilledButton, 'Start sesji'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(PulseSyncTrainer),
        matching: find.widgetWithText(FilledButton, 'Pauza'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('pulse-sync-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 64));

    expect(
      find.byKey(const ValueKey<String>('pulse-sync-finished')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(PulseSyncTrainer), findsNothing);
  });

  testWidgets('pulse sync hides START ZA when countdown reaches START', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PulseSyncTrainer(accent: Colors.green, autoStart: true),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('START ZA'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.byKey(const ValueKey<String>('pulse-sync-countdown-START')),
      findsOneWidget,
    );
    expect(find.text('START ZA'), findsNothing);
  });

  testWidgets('focus scan preview shows only time and points', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FocusScanTrainer(accent: Colors.blue, fullscreenOnStart: true),
        ),
      ),
    );

    expect(find.text('CZAS'), findsOneWidget);
    expect(find.text('PUNKTY'), findsOneWidget);
    expect(find.text('CELNOŚĆ'), findsNothing);
    expect(find.text('SERIA'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Start sesji'), findsOneWidget);
  });

  testWidgets('focus scan fullscreen counts down and closes after finish', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) {
                          return FullscreenTrainerPage(
                            title: 'Skan Koncentracji',
                            accent: Colors.blue,
                            child: const FocusScanTrainer(
                              accent: Colors.blue,
                              autoStart: true,
                              autoExitOnFinish: true,
                            ),
                          );
                        },
                      ),
                    );
                  },
                  child: const Text('Open focus scan'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open focus scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FocusScanTrainer), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('focus-scan-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 49));

    expect(
      find.byKey(const ValueKey<String>('focus-scan-finished')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(FocusScanTrainer), findsNothing);
  });

  testWidgets('focus scan hides START ZA when countdown reaches START', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 760,
            child: FocusScanTrainer(accent: Colors.blue, autoStart: true),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('START ZA'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey<String>('focus-scan-countdown-START')),
      findsOneWidget,
    );
    expect(find.text('START ZA'), findsNothing);
  });

  testWidgets('focus dot preview shows centered start without reset copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: FocusDotTrainer(accent: Colors.blue)),
      ),
    );

    expect(find.widgetWithText(FilledButton, 'Start sesji'), findsOneWidget);
    expect(find.text('Reset'), findsNothing);
    expect(
      find.textContaining('Po starcie zobaczysz tylko punkt'),
      findsNothing,
    );
    expect(
      find.text(
        'Patrz w punkt. Jeśli myśli odpłyną, wróć do środka bez oceniania.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('focus dot switches between new pursuit and peripheral modes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: FocusDotTrainer(accent: Colors.blue)),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('focus-mode-pursuit')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('focus-trainer-pursuit')),
      findsOneWidget,
    );
    expect(find.textContaining('Śledź kropkę samym wzrokiem'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('focus-mode-peripheral')),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Trzymaj wzrok w środku. Tapnij tylko wtedy, gdy po boku mignie jasny sygnał',
      ),
      findsOneWidget,
    );
  });

  testWidgets('speed read preview keeps only centered start launcher', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SpeedReadTrainer(
            accent: Colors.orange,
            fullscreenOnStart: true,
          ),
        ),
      ),
    );

    expect(find.widgetWithText(FilledButton, 'Start sesji'), findsOneWidget);
    expect(find.text('Reset'), findsNothing);
    expect(find.text('Nowy tekst'), findsNothing);
    expect(find.text('Dopasuj tempo'), findsOneWidget);
    expect(find.text('400-1000'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('speed-read-speed-slider')),
      findsOneWidget,
    );
  });

  testWidgets('speed read session counts down and advances automatically', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 760,
            child: SpeedReadSessionView(
              accent: Colors.orange,
              category: SpeedReadCategory.polish,
              level: SpeedReadLevel.one,
              wordsPerMinute: 60,
              autoStart: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('speed-read-countdown-3')),
      findsOneWidget,
    );
    expect(find.text('POZIOM'), findsNothing);
    expect(find.text('TEMPO'), findsNothing);
    expect(find.text('TEKST'), findsNothing);
    expect(find.text('Nowy tekst za chwilę'), findsNothing);
    expect(find.text('Ustaw wzrok w środku'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('speed-read-countdown-2')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('speed-read-countdown-1')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('speed-read-countdown-START')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('speed-read-passage-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('speed-read-word-1-1')),
      findsOneWidget,
    );
    expect(find.text('Łap słowo'), findsNothing);
    expect(
      find.text(
        'Patrz w środek ekranu i pozwól słowom wchodzić bez cofania wzroku.',
      ),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('speed-read-word-1-2')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 8));
    expect(
      find.byKey(const ValueKey<String>('speed-read-countdown-2')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey<String>('speed-read-passage-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('speed-read-word-2-1')),
      findsOneWidget,
    );
  });

  testWidgets('speed read closes automatically after finished series', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) {
                          return const Scaffold(
                            body: SizedBox(
                              height: 760,
                              child: SpeedReadSessionView(
                                accent: Colors.orange,
                                category: SpeedReadCategory.polish,
                                level: SpeedReadLevel.one,
                                initialPassageIndex: 19,
                                wordsPerMinute: 1000,
                                autoStart: true,
                                autoExitOnFinish: true,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                  child: const Text('Open speed read'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open speed read'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SpeedReadSessionView), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(
      find.byKey(const ValueKey<String>('speed-read-finished')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(SpeedReadSessionView), findsNothing);
  });

  testWidgets('focus dot waits through 3 2 1 START before session timer runs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FocusDotSessionPage(accent: Colors.blue, minutes: 1),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('focus-dot-countdown-3')),
      findsOneWidget,
    );
    expect(find.text('01:00'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('focus-dot-countdown-2')),
      findsOneWidget,
    );
    expect(find.text('01:00'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('focus-dot-countdown-1')),
      findsOneWidget,
    );
    expect(find.text('01:00'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('focus-dot-countdown-START')),
      findsOneWidget,
    );
    expect(find.text('01:00'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('01:00'), findsOneWidget);
    expect(find.text('Skupienie'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:59'), findsOneWidget);
  });

  testWidgets('focus dot shows end state and closes automatically', (
    WidgetTester tester,
  ) async {
    bool? completed;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    completed = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (BuildContext context) {
                          return const FocusDotSessionPage(
                            accent: Colors.blue,
                            minutes: 0,
                          );
                        },
                      ),
                    );
                  },
                  child: const Text('Open focus dot'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open focus dot'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FocusDotSessionPage), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));

    expect(
      find.byKey(const ValueKey<String>('focus-dot-finished')),
      findsOneWidget,
    );
    expect(find.text('Zakończ'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(FocusDotSessionPage), findsNothing);
    expect(completed, isTrue);
  });

  testWidgets(
    'smooth pursuit waits through 3 2 1 START before tracking starts',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SmoothPursuitSessionPage(accent: Colors.blue, minutes: 1),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('smooth-pursuit-countdown-3')),
        findsOneWidget,
      );
      expect(find.text('01:00'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey<String>('smooth-pursuit-countdown-2')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey<String>('smooth-pursuit-countdown-1')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey<String>('smooth-pursuit-countdown-START')),
        findsOneWidget,
      );
      expect(find.text('01:00'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey<String>('smooth-pursuit-active')),
        findsOneWidget,
      );
      expect(find.text('01:00'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00:59'), findsOneWidget);
    },
  );

  testWidgets('peripheral focus scores after a correct tap', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PeripheralFocusSessionPage(accent: Colors.blue, minutes: 1),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('peripheral-focus-countdown-3')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(
        const ValueKey<String>('peripheral-focus-stimulus-right-target'),
      ),
      findsOneWidget,
    );
    expect(find.text('Punkty 0'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
    await tester.pump();

    expect(find.text('Punkty 1'), findsOneWidget);
  });

  testWidgets('split decision loads persisted daily best records', (
    WidgetTester tester,
  ) async {
    final todayKey = _todayKey();
    final formattedToday =
        '${todayKey.substring(8, 10)}.${todayKey.substring(5, 7)}.${todayKey.substring(0, 4)}';

    SharedPreferences.setMockInitialValues(<String, Object>{
      'split_decision_session_history_v1': jsonEncode(<Map<String, Object>>[
        <String, Object>{
          'dateKey': todayKey,
          'completedAtIso': '${todayKey}T09:15:00.000',
          'level': 4,
          'accuracyPercent': 93,
          'averageReactionMs': 281,
          'bestStreak': 18,
          'correctDecisions': 40,
          'tapHits': 18,
          'tapOpportunities': 21,
          'errors': 3,
          'presented': 43,
        },
        <String, Object>{
          'dateKey': todayKey,
          'completedAtIso': '${todayKey}T08:40:00.000',
          'level': 2,
          'accuracyPercent': 88,
          'averageReactionMs': 420,
          'bestStreak': 11,
          'correctDecisions': 22,
          'tapHits': 9,
          'tapOpportunities': 12,
          'errors': 4,
          'presented': 26,
        },
      ]),
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SplitDecisionTrainer(accent: Colors.blue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rootScrollView = find.byType(SingleChildScrollView).first;
    await tester.dragUntilVisible(
      find.text('Najlepsze wyniki dnia'),
      rootScrollView,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(find.text('Najlepsze wyniki dnia'), findsOneWidget);
    expect(
      find.textContaining('Dzisiaj zapisane poziomy: 2, 4'),
      findsOneWidget,
    );

    await tester.tap(find.text('Najlepsze wyniki dnia'));
    await tester.pumpAndSettle();

    expect(find.text(formattedToday), findsOneWidget);
    expect(find.text('Poziom 4'), findsWidgets);
    expect(find.text('Poziom 2'), findsWidgets);
    expect(find.text('Trafione: 18/21'), findsOneWidget);
    expect(find.text('Trafione: 9/12'), findsOneWidget);
    expect(find.textContaining('Reakcja'), findsNothing);
  });

  testWidgets('flow home loads persisted completed progress cycle', (
    WidgetTester tester,
  ) async {
    final todayKey = _todayKey();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flow_home_progress_v2': jsonEncode(<String, Object>{
        'activeDateKey': todayKey,
        'completedKinds': ExerciseKind.values
            .map((ExerciseKind kind) => kind.name)
            .toList(),
        'currentCycleRecordId': 'progress-1',
        'entries': <Map<String, Object>>[
          <String, Object>{
            'id': 'progress-1',
            'dateKey': todayKey,
            'completedAtIso': DateTime.now().toIso8601String(),
          },
        ],
      }),
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Progres ukończono'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('flow-progress-next-cycle')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('flow-progress-next-cycle')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Progres ukończono'), findsNothing);
    expect(
      find.textContaining('0 z ${exerciseDefinitions.length} ćwiczeń'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Dzisiaj ukończono już 1 progres'),
      findsOneWidget,
    );
  });

  testWidgets('flow calendar removes saved progress after long press', (
    WidgetTester tester,
  ) async {
    final todayKey = _todayKey();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flow_home_progress_v2': jsonEncode(<String, Object>{
        'activeDateKey': todayKey,
        'completedKinds': const <String>[],
        'entries': <Map<String, Object>>[
          <String, Object>{
            'id': 'progress-1',
            'dateKey': todayKey,
            'completedAtIso': DateTime.now().toIso8601String(),
          },
        ],
      }),
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final calendarToggleFinder = find.byKey(
      const ValueKey<String>('flow-calendar-toggle'),
    );
    await tester.scrollUntilVisible(
      calendarToggleFinder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(calendarToggleFinder);
    await tester.pump();

    await tester.tap(calendarToggleFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final progressRecordFinder = find.byKey(
      const ValueKey<String>('flow-progress-record-progress-1'),
    );
    await tester.scrollUntilVisible(
      progressRecordFinder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(progressRecordFinder);
    await tester.pump();

    expect(find.text('Ukończono Progres'), findsOneWidget);

    await tester.longPress(progressRecordFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Usunąć zapis?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Usuń'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Ukończono Progres'), findsNothing);
    expect(
      find.text('Ten dzień nie ma jeszcze zapisanych aktywności.'),
      findsOneWidget,
    );
  });

  testWidgets('flow calendar shows synced hero daily completions', (
    WidgetTester tester,
  ) async {
    final todayKey = _todayKey();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mnemonic_morning_review_v1': todayKey,
      'mnemonic_morning_review_count_v1': 3,
      'training_daily_completed_date_v1': todayKey,
      'training_daily_completed_count_v1': 3,
      'straw_daily_completed_date_v1': todayKey,
      'straw_daily_completed_count_v1': 3,
    });

    await tester.pumpWidget(const MyApp(showLaunchExperience: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final calendarToggleFinder = find.byKey(
      const ValueKey<String>('flow-calendar-toggle'),
    );
    await tester.scrollUntilVisible(
      calendarToggleFinder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(calendarToggleFinder);
    await tester.pump();

    await tester.tap(calendarToggleFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.text('Przytrzymaj zapisany progres, żeby go usunąć.'),
      findsNothing,
    );
    expect(find.text('Ukończono Pamięć'), findsOneWidget);
    expect(find.text('Ukończono Wibrację'), findsOneWidget);
    expect(find.text('Ukończono Trening'), findsOneWidget);
  });

  testWidgets('split decision removes saved day level after long press', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'split_decision_session_history_v1': jsonEncode(<Map<String, Object>>[
        <String, Object>{
          'dateKey': '2026-03-27',
          'completedAtIso': '2026-03-27T09:15:00.000',
          'level': 4,
          'accuracyPercent': 93,
          'averageReactionMs': 281,
          'bestStreak': 18,
          'correctDecisions': 40,
          'tapHits': 18,
          'tapOpportunities': 21,
          'errors': 3,
          'presented': 43,
        },
        <String, Object>{
          'dateKey': '2026-03-27',
          'completedAtIso': '2026-03-27T08:40:00.000',
          'level': 2,
          'accuracyPercent': 88,
          'averageReactionMs': 420,
          'bestStreak': 11,
          'correctDecisions': 22,
          'tapHits': 9,
          'tapOpportunities': 12,
          'errors': 4,
          'presented': 26,
        },
      ]),
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SplitDecisionTrainer(accent: Colors.blue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rootScrollView = find.byType(SingleChildScrollView).first;
    await tester.dragUntilVisible(
      find.text('Najlepsze wyniki dnia'),
      rootScrollView,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Najlepsze wyniki dnia'));
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('Trafione: 18/21'),
      rootScrollView,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    expect(find.text('Trafione: 18/21'), findsOneWidget);

    await tester.longPress(find.text('Trafione: 18/21'));
    await tester.pumpAndSettle();

    expect(find.text('Usunąć zapisany wynik?'), findsOneWidget);

    await tester.tap(find.text('Usuń'));
    await tester.pumpAndSettle();

    expect(find.text('Trafione: 18/21'), findsNothing);
    expect(find.text('Trafione: 9/12'), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    final rawHistory = preferences.getString(
      'split_decision_session_history_v1',
    );

    expect(rawHistory, isNotNull);

    final decoded = jsonDecode(rawHistory!) as List<dynamic>;
    expect(decoded, hasLength(1));
    expect(
      Map<String, dynamic>.from(
        decoded.single as Map<dynamic, dynamic>,
      )['level'],
      2,
    );
  });

  testWidgets('split decision stores zero hits without any taps', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenTrainerPage(
          title: 'Split Decision',
          accent: Colors.blue,
          expandBody: true,
          child: const SplitDecisionTrainer(
            accent: Colors.blue,
            immersiveLayout: true,
            autoStart: true,
          ),
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 124));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    final rawHistory = preferences.getString(
      'split_decision_session_history_v1',
    );

    expect(rawHistory, isNotNull);

    final decoded = jsonDecode(rawHistory!) as List<dynamic>;
    expect(decoded, isNotEmpty);

    final latestRecord = Map<String, dynamic>.from(
      decoded.first as Map<dynamic, dynamic>,
    );

    expect(latestRecord['tapHits'], 0);
    expect(latestRecord['tapOpportunities'], isA<int>());
  });
}
