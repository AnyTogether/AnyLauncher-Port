import 'dart:async';

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
    final conversation = target is ConversationTarget ? (target as ConversationTarget).conversation : null;
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
    final muted = conversation?.muted == true;
    return GestureDetector(
      onTap: () {
        final index = together.messageTargets.indexOf(target);
        if (index < 0) return;
        together.messagesIndex = index;
        together.messagesInThread = false;
        model.handle(Command.select);
      },
      // Right-click: pin it, mute it.
      onSecondaryTap: conversation == null ? null : () => together.openConversationMenu(conversation),
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.display(16 * scale, weight: FontWeight.w600, color: color),
                        ),
                      ),
                      if (conversation?.pinned == true)
                        _Mark(icon: Icons.push_pin_rounded, label: T.text('conversationPinned'), color: color),
                      if (muted)
                        _Mark(icon: Icons.notifications_off_rounded, label: T.text('conversationMuted'), color: color),
                    ],
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
                  // Muted: counted, quietly.
                  color: muted ? color.withValues(alpha: 0.18) : model.accentChoice.color,
                  borderRadius: BorderRadius.circular(11 * scale),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: AppText.display(
                    12 * scale,
                    weight: FontWeight.w700,
                    color: muted ? color : LookScope.inkOnAccent(context, model.accentChoice.color, Colors.black),
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
    final listed = target is ConversationTarget ? (target as ConversationTarget).conversation : null;
    // The list's copy can be a moment older than the one the events keep.
    final conversation = messages.byId(listed?.id) ?? listed;
    final title = switch (target) {
      ConversationTarget(:final conversation) => conversation.name(me),
      FriendTarget(:final friend) => friend.person.displayName,
    };
    final showing = conversation != null && messages.openId == conversation.id;
    final thread = showing ? messages.thread : const <ChatMessage>[];
    final typing = showing ? messages.typingIn(conversation.id) : const <String>[];
    final inThread = together.messagesInThread;
    final accent = model.accentChoice.color;
    final focused = inThread ? together.focusedMessage : null;
    final receiptOn = showing ? together.receiptFor(conversation) : null;
    final note = showing ? together.composerNote : null;
    final menu = together.messageMenu;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display(26 * scale, weight: FontWeight.w400),
                  ),
                ),
                // △: the conversation's options, or the message's the keys are on.
                if (conversation != null)
                  Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('hintOptions'), action: HintAction.options),
              ],
            ),
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
                      // Room for the focus ring of a message at the edge.
                      padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
                      children: [
                        for (final message in thread.reversed)
                          KeepVisible(
                            active: focused?.id == message.id,
                            child: _Bubble(
                              message: message,
                              mine: message.authorId == me,
                              me: me,
                              author: conversation?.group == true
                                  ? together.authorName(conversation, message.authorId)
                                  : null,
                              accent: accent,
                              focused: focused?.id == message.id && menu == null,
                              quote: together.quoteOf(message),
                              receipt: receiptOn?.id == message.id && conversation != null
                                  ? together.receiptText(conversation, message)
                                  : null,
                              onTap: () {
                                if (message.failed) {
                                  unawaited(messages.retry(message));
                                } else {
                                  together.openMessageMenu(message);
                                }
                              },
                              onReaction: (name) => unawaited(together.toggleReaction(message, name)),
                            ),
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
            if (note != null)
              _ComposerNote(title: note.$1, text: note.$2, accent: accent, onCancel: together.cancelComposerNote),
            Row(
              children: [
                for (var index = 0; index < TogetherMessages.quickReplies.length; index++) ...[
                  _Chip(
                    label: TogetherMessages.quickReplies[index],
                    focused: inThread && focused == null && together.messageFocus == index,
                    onTap: () => together.sendMessage(TogetherMessages.quickReplies[index]),
                  ),
                  SizedBox(width: 10 * scale),
                ],
                Expanded(
                  child: FocusRing(
                    focused:
                        inThread &&
                        focused == null &&
                        together.messageFocus == TogetherMessages.composer &&
                        model.editingRow == null,
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
        ),
        if (menu != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: together.closeMessageMenu,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: GestureDetector(
                    onTap: () {},
                    child: _MenuCard(model: model, menu: menu),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A small mark beside a conversation's name: pinned, muted.
class _Mark extends StatelessWidget {
  const _Mark({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 6 * scale),
      child: Semantics(
        label: label,
        child: Icon(icon, size: 14 * scale, color: color.withValues(alpha: 0.55)),
      ),
    );
  }
}

/// Above the composer while it answers a message or edits one: what, and a way out.
class _ComposerNote extends StatelessWidget {
  const _ComposerNote({required this.title, required this.text, required this.accent, required this.onCancel});

  final String title;
  final String text;
  final Color accent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: 10 * scale),
      padding: EdgeInsets.fromLTRB(14 * scale, 8 * scale, 8 * scale, 8 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12 * scale),
        border: Border(
          left: BorderSide(color: accent, width: 3 * scale),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppText.display(12 * scale, weight: FontWeight.w700, color: accent),
                ),
                SizedBox(height: 2 * scale),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: T.text('cancel'),
            child: Pressable(
              onTap: onCancel,
              builder: (context, hovering) => Padding(
                padding: EdgeInsets.all(6 * scale),
                child: Icon(
                  Icons.close_rounded,
                  size: 18 * scale,
                  color: Colors.white.withValues(alpha: hovering ? 0.9 : 0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The menu over the thread: a message's reactions and what can be done with it, asking before
/// it is unsent; or a conversation's pin and mute.
class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.model, required this.menu});

  final AppModel model;
  final MessageMenu menu;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final together = model.together;
    final items = together.messageMenuItems;
    final message = menu.message;
    final conversation = together.hub.messages.byId(menu.conversationId);
    final me = together.user?.id;
    final heading = menu.confirming
        ? T.text('messagesUnsendConfirm')
        : message != null
        ? (message.words ?? '')
        : conversation?.name(me) ?? '';
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 420 * scale),
      child: Glass(
        radius: 22 * scale,
        opacity: 0.85,
        padding: EdgeInsets.all(18 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(6 * scale, 0, 6 * scale, 12 * scale),
              child: Text(
                heading,
                maxLines: menu.confirming ? 4 : 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(
                  menu.confirming ? 16 * scale : 14 * scale,
                  weight: menu.confirming ? FontWeight.w600 : FontWeight.w400,
                  color: Colors.white.withValues(alpha: menu.confirming ? 0.95 : 0.6),
                  height: 1.3,
                ),
              ),
            ),
            for (var index = 0; index < items.length; index++)
              if (items[index] == 'react')
                _ReactionPicker(
                  message: message!,
                  me: me,
                  focused: menu.row == index,
                  chosen: menu.reaction,
                  onPick: (at) {
                    menu
                      ..row = index
                      ..reaction = at;
                    together.runMenuItem('react');
                  },
                )
              else
                _MenuRow(
                  label: together.menuLabel(items[index]),
                  focused: menu.row == index,
                  destructive: items[index] == 'unsend' || items[index] == 'unsend-confirm',
                  onTap: () {
                    menu.row = index;
                    together.runMenuItem(items[index]);
                  },
                ),
          ],
        ),
      ),
    );
  }
}

class _ReactionPicker extends StatelessWidget {
  const _ReactionPicker({
    required this.message,
    required this.me,
    required this.focused,
    required this.chosen,
    required this.onPick,
  });

  final ChatMessage message;
  final String? me;
  final bool focused;
  final int chosen;
  final void Function(int index) onPick;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final name = messageReactions[chosen];
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var index = 0; index < messageReactions.length; index++)
                Semantics(
                  button: true,
                  label: TogetherMessages.reactionLabel(messageReactions[index]),
                  child: Pressable(
                    onTap: () => onPick(index),
                    builder: (context, hovering) {
                      final on = focused && index == chosen;
                      final mine = message.reacted(messageReactions[index], me);
                      return AnimatedContainer(
                        duration: Motion.focus,
                        curve: Motion.settle,
                        width: 46 * scale,
                        height: 46 * scale,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on
                              ? Colors.white
                              : Colors.white.withValues(alpha: mine ? 0.22 : (hovering ? 0.14 : 0.06)),
                        ),
                        child: Text(
                          reactionGlyphs[messageReactions[index]]!,
                          style: AppText.display(
                            messageReactions[index] == 'gg' ? 15 * scale : 21 * scale,
                            weight: FontWeight.w800,
                            color: on ? Colors.black : Colors.white,
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
          SizedBox(height: 6 * scale),
          Text(
            focused ? TogetherMessages.reactionLabel(name) : T.text('messagesReact'),
            textAlign: TextAlign.center,
            style: AppText.display(12 * scale, color: Colors.white.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.focused, required this.destructive, required this.onTap});

  final String label;
  final bool focused;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final ink = destructive ? Palette.danger : Colors.white;
    return Pressable(
      onTap: onTap,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        margin: EdgeInsets.only(top: 4 * scale),
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 12 * scale),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: hovering ? 0.1 : 0),
          borderRadius: BorderRadius.circular(12 * scale),
        ),
        child: Text(
          label,
          style: AppText.display(
            15 * scale,
            weight: FontWeight.w600,
            color: focused ? (destructive ? const Color(0xFFB3261E) : Colors.black) : ink,
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.me,
    required this.accent,
    required this.focused,
    required this.onTap,
    required this.onReaction,
    this.author,
    this.quote,
    this.receipt,
  });

  final ChatMessage message;
  final bool mine;
  final String? me;
  final Color accent;
  final String? author;
  final bool focused;

  /// Who wrote the message it answers, and what.
  final (String, String)? quote;

  /// Under the user's newest message: Sent, Delivered, Read, Seen by.
  final String? receipt;
  final VoidCallback onTap;
  final void Function(String name) onReaction;

  @override
  Widget build(BuildContext context) {
    // Words on the accent: dark ink on a light one (Glass, or the Ice accent).
    final mineInk = LookScope.inkOnAccent(context, accent, Colors.black);
    final scale = LayoutScale.of(context);
    final ink = mine ? mineInk : Colors.white;
    final text = message.deleted ? T.text('messagesDeleted') : (message.text ?? '');
    final foot = [
      if (message.failed) T.text('messagesRetry'),
      if (message.edited && !message.deleted) T.text('messagesEdited'),
    ];
    final radius = BorderRadius.only(
      topLeft: Radius.circular(18 * scale),
      topRight: Radius.circular(18 * scale),
      bottomLeft: Radius.circular((mine ? 18 : 5) * scale),
      bottomRight: Radius.circular((mine ? 5 : 18) * scale),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * scale),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 560 * scale),
            child: FocusRing(
              focused: focused,
              radius: 18 * scale,
              child: GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 10 * scale),
                  decoration: BoxDecoration(
                    color: message.deleted
                        ? Colors.white.withValues(alpha: 0.04)
                        : mine
                        ? accent.withValues(alpha: message.pending ? 0.45 : 0.85)
                        : Colors.white.withValues(alpha: 0.1),
                    borderRadius: radius,
                    border: message.failed
                        ? Border.all(color: Palette.danger, width: 1.5 * scale)
                        : message.deleted
                        ? Border.all(color: Colors.white.withValues(alpha: 0.14), width: 1 * scale)
                        : null,
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
                      if (quote != null && !message.deleted)
                        Container(
                          margin: EdgeInsets.only(bottom: 6 * scale),
                          padding: EdgeInsets.fromLTRB(10 * scale, 4 * scale, 8 * scale, 4 * scale),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(color: ink.withValues(alpha: 0.45), width: 2.5 * scale),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (quote!.$1.isNotEmpty)
                                Text(
                                  quote!.$1,
                                  style: AppText.display(
                                    12 * scale,
                                    weight: FontWeight.w700,
                                    color: ink.withValues(alpha: 0.75),
                                  ),
                                ),
                              Text(
                                quote!.$2,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.display(13 * scale, color: ink.withValues(alpha: 0.65), height: 1.25),
                              ),
                            ],
                          ),
                        ),
                      Text(
                        text,
                        style: AppText.display(
                          16 * scale,
                          color: message.deleted
                              ? Colors.white.withValues(alpha: 0.5)
                              : mine
                              ? mineInk
                              : Colors.white.withValues(alpha: 0.95),
                          height: 1.3,
                        ).copyWith(fontStyle: message.deleted ? FontStyle.italic : null),
                      ),
                      if (foot.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(top: 4 * scale),
                          child: Text(
                            foot.join(' · '),
                            style: AppText.display(11 * scale, color: ink.withValues(alpha: 0.6)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (message.reactions.isNotEmpty && !message.deleted)
            Padding(
              padding: EdgeInsets.only(top: 4 * scale),
              child: Wrap(
                spacing: 6 * scale,
                runSpacing: 4 * scale,
                children: [
                  for (final reaction in message.reactions)
                    _ReactionChip(
                      reaction: reaction,
                      mine: reaction.userIds.contains(me),
                      accent: accent,
                      onTap: () => onReaction(reaction.name),
                    ),
                ],
              ),
            ),
          if (receipt != null)
            Padding(
              padding: EdgeInsets.only(top: 3 * scale, right: 4 * scale),
              child: Text(
                receipt!,
                style: AppText.display(11 * scale, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.5)),
              ),
            ),
        ],
      ),
    );
  }
}

/// A reaction under a bubble: its glyph and how many (when more than one), lit when it is the
/// user's; clicked, added or taken back.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.reaction, required this.mine, required this.accent, required this.onTap});

  final ReactionCount reaction;
  final bool mine;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Semantics(
      button: true,
      label: TogetherMessages.reactionLabel(reaction.name),
      child: Pressable(
        onTap: onTap,
        builder: (context, hovering) => AnimatedContainer(
          duration: Motion.focus,
          curve: Motion.settle,
          padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
          decoration: BoxDecoration(
            color: mine ? accent.withValues(alpha: 0.28) : Colors.white.withValues(alpha: hovering ? 0.16 : 0.09),
            borderRadius: BorderRadius.circular(12 * scale),
            border: Border.all(
              color: mine ? accent.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.12),
              width: 1 * scale,
            ),
          ),
          child: Text(
            reaction.count > 1 ? '${reactionGlyphs[reaction.name]} ${reaction.count}' : reactionGlyphs[reaction.name]!,
            style: AppText.display(12 * scale, weight: FontWeight.w700, color: Colors.white),
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
