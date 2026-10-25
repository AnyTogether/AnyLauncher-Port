import 'package:flutter/material.dart';

import '../core/together/messages.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'panels.dart';
import 'strings.dart';
import 'theme.dart';
import 'together_model.dart';

/// Messages: the conversations and friends on the left, the thread on the right with the quick
/// replies a controller can send and a field to type in.
class MessagesView extends StatelessWidget {
  const MessagesView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final targets = together.messageTargets;
    final selected = together.selectedTarget;
    return LayerScrim(
      opacity: 0.62,
      child: Padding(
        padding: EdgeInsets.fromLTRB(80 * scale, 60 * scale, 80 * scale, 50 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 440 * scale,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T.text('messagesTitle'), style: AppText.display(40 * scale, weight: FontWeight.w300)),
                  SizedBox(height: 24 * scale),
                  Expanded(
                    child: targets.isEmpty
                        ? Text(
                            together.signedIn ? T.text('messagesNone') : T.text('friendsSignIn'),
                            style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.6)),
                          )
                        : SingleChildScrollView(
                            child: Column(
                              children: [
                                for (var index = 0; index < targets.length; index++)
                                  KeepVisible(
                                    active: index == together.messagesIndex,
                                    child: _TargetRow(
                                      model: model,
                                      target: targets[index],
                                      selected: index == together.messagesIndex,
                                      focused: index == together.messagesIndex && !together.messagesInThread,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 36 * scale),
            Expanded(
              child: Glass(
                radius: 26 * scale,
                opacity: 0.45,
                padding: EdgeInsets.all(28 * scale),
                child: selected == null ? const SizedBox.expand() : _Thread(model: model, target: selected),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.model, required this.target, required this.selected, required this.focused});

  final AppModel model;
  final MessageTarget target;
  final bool selected;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final me = together.user?.id;
    final (String name, String detail, int unread, PanelPerson person) = switch (target) {
      ConversationTarget(:final conversation) => (
        conversation.name(me),
        _preview(conversation, me),
        conversation.unread,
        PanelPerson(
          name: conversation.name(me),
          avatar: conversation.group ? null : conversation.others(me).firstOrNull?.avatar,
          status: conversation.group
              ? null
              : together.hub.friends
                    .byId(conversation.others(me).firstOrNull?.id ?? '')
                    ?.presence
                    .let(TogetherModel.status),
        ),
      ),
      FriendTarget(:final friend) => (
        friend.person.displayName,
        T.text('messagesSayHello'),
        0,
        TogetherModel.card(friend.person, status: TogetherModel.status(friend.presence)),
      ),
    };
    final color = focused ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: () {
        final index = together.messageTargets.indexOf(target);
        if (index < 0) return;
        together.messagesIndex = index;
        together.messagesInThread = false;
        model.handle(Command.select);
      },
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        margin: EdgeInsets.only(bottom: 6 * scale),
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: selected ? 0.12 : 0.05),
          borderRadius: BorderRadius.circular(14 * scale),
        ),
        child: Row(
          children: [
            PersonAvatar(person: person, size: 42 * scale, focused: focused),
            SizedBox(width: 14 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(16 * scale, weight: FontWeight.w600, color: color),
                  ),
                  SizedBox(height: 3 * scale),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(13 * scale, color: color.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
            if (unread > 0)
              Container(
                constraints: BoxConstraints(minWidth: 22 * scale),
                height: 22 * scale,
                padding: EdgeInsets.symmetric(horizontal: 6 * scale),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: model.accentChoice.color,
                  borderRadius: BorderRadius.circular(11 * scale),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: AppText.display(
                    12 * scale,
                    weight: FontWeight.w700,
                    color: LookScope.inkOnAccent(context, model.accentChoice.color, Colors.black),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _preview(Conversation conversation, String? me) {
    final last = conversation.lastMessage;
    if (last == null) return T.text('messagesSayHello');
    if (last.deleted) return T.text('messagesDeleted');
    final text = last.text ?? '';
    if (last.authorId == me) return T.format('messagesYou', [text]);
    if (conversation.group) {
      return T.format('messagesFrom', [conversation.author(last.authorId)?.displayName ?? '', text]);
    }
    return text;
  }
}

extension<T> on T {
  R let<R>(R Function(T) transform) => transform(this);
}

class _Thread extends StatelessWidget {
  const _Thread({required this.model, required this.target});

  final AppModel model;
  final MessageTarget target;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final messages = together.hub.messages;
    final me = together.user?.id;
    final conversation = target is ConversationTarget ? (target as ConversationTarget).conversation : null;
    final title = switch (target) {
      ConversationTarget(:final conversation) => conversation.name(me),
      FriendTarget(:final friend) => friend.person.displayName,
    };
    final showing = conversation != null && messages.openId == conversation.id;
    final thread = showing ? messages.thread : const <ChatMessage>[];
    final typing = showing ? messages.typingIn(conversation.id) : const <String>[];
    final inThread = together.messagesInThread;
    final accent = model.accentChoice.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.display(26 * scale, weight: FontWeight.w400)),
        SizedBox(height: 14 * scale),
        Expanded(
          child: thread.isEmpty
              ? Center(
                  child: Text(
                    messages.loadingThread ? T.text('profileLoading') : T.text('messagesEmptyThread'),
                    style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.5)),
                  ),
                )
              : ListView(
                  reverse: true,
                  children: [
                    for (final message in thread.reversed)
                      _Bubble(
                        message: message,
                        mine: message.authorId == me,
                        author: conversation?.group == true
                            ? together.authorName(conversation, message.authorId)
                            : null,
                        accent: accent,
                      ),
                  ],
                ),
        ),
        SizedBox(
          height: 26 * scale,
          child: typing.isEmpty
              ? null
              : Text(
                  T.format('messagesTyping', [together.authorName(conversation, typing.first)]),
                  style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.6)),
                ),
        ),
        Row(
          children: [
            for (var index = 0; index < TogetherMessages.quickReplies.length; index++) ...[
              _Chip(
                label: TogetherMessages.quickReplies[index],
                focused: inThread && together.messageFocus == index,
                onTap: () => together.sendMessage(TogetherMessages.quickReplies[index]),
              ),
              SizedBox(width: 10 * scale),
            ],
            Expanded(
              child: FocusRing(
                focused: inThread && together.messageFocus == TogetherMessages.composer && model.editingRow == null,
                radius: 12 * scale,
                child: RowTextField(
                  model: model,
                  row: together.draftField,
                  kind: together.draftField.kind as TextRow,
                  focused: false,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.accent, this.author});

  final ChatMessage message;
  final bool mine;
  final Color accent;
  final String? author;

  @override
  Widget build(BuildContext context) {
    // Words on the accent: dark ink on a light one (Glass, or the Ice accent).
    final mineInk = LookScope.inkOnAccent(context, accent, Colors.black);
    final scale = LayoutScale.of(context);
    final text = message.deleted ? T.text('messagesDeleted') : (message.text ?? '');
    final foot = [
      if (message.failed) T.text('messagesRetry'),
      if (message.edited && !message.deleted) T.text('messagesEdited'),
    ];
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560 * scale),
        child: Container(
          margin: EdgeInsets.only(bottom: 8 * scale),
          padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 10 * scale),
          decoration: BoxDecoration(
            color: mine ? accent.withValues(alpha: message.pending ? 0.45 : 0.85) : Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(18 * scale),
              topRight: Radius.circular(18 * scale),
              bottomLeft: Radius.circular((mine ? 18 : 5) * scale),
              bottomRight: Radius.circular((mine ? 5 : 18) * scale),
            ),
            border: message.failed ? Border.all(color: Palette.danger, width: 1.5 * scale) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (author != null && !mine)
                Padding(
                  padding: EdgeInsets.only(bottom: 3 * scale),
                  child: Text(
                    author!,
                    style: AppText.display(12 * scale, weight: FontWeight.w700, color: accent),
                  ),
                ),
              Text(
                text,
                style: AppText.display(
                  16 * scale,
                  color: mine ? mineInk : Colors.white.withValues(alpha: message.deleted ? 0.5 : 0.95),
                  height: 1.3,
                ),
              ),
              if (foot.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: 4 * scale),
                  child: Text(
                    foot.join(' · '),
                    style: AppText.display(11 * scale, color: (mine ? mineInk : Colors.white).withValues(alpha: 0.6)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.focused, required this.onTap});

  final String label;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 11 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(22 * scale),
          boxShadow: [
            BoxShadow(
              color: Colors.white.withValues(alpha: focused ? 0.3 : 0),
              blurRadius: 12 * scale,
            ),
          ],
        ),
        child: Text(
          label,
          style: AppText.display(15 * scale, weight: FontWeight.w600, color: focused ? Colors.black : Colors.white),
        ),
      ),
    );
  }
}
