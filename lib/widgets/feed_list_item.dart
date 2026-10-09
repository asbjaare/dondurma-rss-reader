import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/feed_item.dart';
import '../providers/bookmark_provider.dart';
import '../providers/feed_provider.dart';
import '../services/image_cache_service.dart';

/// Cuts [text] to at most [maxChars] characters, ending with an ellipsis.
/// Keeps both the site name and the category visible in the meta row: without
/// per-segment limits a long site name pushes the category off screen.
const int _articleNavigationWindowRadius = 25;

String truncateLabel(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars - 1)}…';
}

class FeedListItem extends StatefulWidget {
  final FeedItem item;

  const FeedListItem({super.key, required this.item});

  @override
  State<FeedListItem> createState() => _FeedListItemState();
}

class _FeedListItemState extends State<FeedListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  Animation<double>? _snapBackAnimation;
  double _dragExtent = 0.0;
  bool _actionTriggered = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 250),
        )..addListener(() {
          if (_snapBackAnimation != null) {
            setState(() {
              _dragExtent = _snapBackAnimation!.value;
            });
          }
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_controller.isAnimating) return;
    final prev = _actionTriggered;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final threshold = width * 0.25;
    setState(() {
      _dragExtent += details.primaryDelta!;
    });
    if (!prev && _dragExtent.abs() > threshold) {
      _actionTriggered = true;
      HapticFeedback.mediumImpact();
      setState(() {});
    } else if (prev && _dragExtent.abs() <= threshold) {
      _actionTriggered = false;
      HapticFeedback.selectionClick();
      setState(() {});
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_controller.isAnimating) return;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final threshold = width * 0.25;
    final velocity = details.primaryVelocity ?? 0.0;

    if (_dragExtent > 0 && (_dragExtent > threshold || velocity > 1500)) {
      context.read<FeedProvider>().toggleReadStatus(widget.item.id);
    } else if (_dragExtent < 0 &&
        (_dragExtent < -threshold || velocity < -1500)) {
      context.read<BookmarkProvider>().toggleBookmark(widget.item);
    }

    _actionTriggered = false;
    _snapBackAnimation = Tween<double>(
      begin: _dragExtent,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final isSwipingRight = _dragExtent > 0;

    return Selector2<
      FeedProvider,
      BookmarkProvider,
      ({bool isCached, bool isBookmarked})
    >(
      selector: (context, feedProvider, bookmarkProvider) => (
        isCached: feedProvider.cachedItemIds.contains(widget.item.id),
        isBookmarked: bookmarkProvider.bookmarkedItemIds.contains(
          widget.item.id,
        ),
      ),
      builder: (context, state, child) {
        final bool isBookmarked = state.isBookmarked;
        final bool isCached = state.isCached;
        final bool isRead = widget.item.isRead;
        final l10n = AppLocalizations.of(context);

        return Semantics(
          label: l10n.semanticOpenArticle(widget.item.title),
          hint: isRead ? l10n.semanticArticleRead : l10n.semanticArticleUnread,
          button: false,
          // Swipe gestures are invisible to screen readers; expose both swipe
          // actions as custom semantics actions so TalkBack users can reach
          // them from the card itself.
          customSemanticsActions: {
            CustomSemanticsAction(
              label: isRead
                  ? l10n.semanticMarkAsUnread
                  : l10n.semanticMarkAsRead,
            ): () =>
                context.read<FeedProvider>().toggleReadStatus(widget.item.id),
            CustomSemanticsAction(
              label: isBookmarked
                  ? l10n.semanticRemoveBookmark
                  : l10n.semanticBookmark,
            ): () =>
                context.read<BookmarkProvider>().toggleBookmark(widget.item),
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10.0),
            child: Stack(
              children: [
                if (_dragExtent != 0)
                  _SwipeBackground(
                    isSwipingRight: isSwipingRight,
                    isRead: isRead,
                    isBookmarked: isBookmarked,
                    actionTriggered: _actionTriggered,
                  ),
                GestureDetector(
                  onHorizontalDragUpdate: _onHorizontalDragUpdate,
                  onHorizontalDragEnd: _onHorizontalDragEnd,
                  child: Transform.translate(
                    offset: Offset(_dragExtent, 0),
                    child: _ArticleCard(
                      item: widget.item,
                      isRead: isRead,
                      isBookmarked: isBookmarked,
                      isCached: isCached,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// Core card widget
// =============================================================================

class _ArticleCard extends StatelessWidget {
  final FeedItem item;
  final bool isRead;
  final bool isBookmarked;
  final bool isCached;

  const _ArticleCard({
    required this.item,
    required this.isRead,
    required this.isBookmarked,
    required this.isCached,
  });

  bool get _hasThumbnail => item.imageUrl != null && item.imageUrl!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          final feedProvider = context.read<FeedProvider>();
          final allItems = feedProvider.filteredItems;
          final index = allItems.indexWhere((i) => i.id == item.id);
          final safeIndex = index >= 0 ? index : 0;
          final start = (safeIndex - _articleNavigationWindowRadius)
              .clamp(0, allItems.length)
              .toInt();
          final end = (safeIndex + _articleNavigationWindowRadius + 1)
              .clamp(0, allItems.length)
              .toInt();
          final articleItems = allItems.sublist(start, end);
          context.push(
            '/article',
            extra: {'items': articleItems, 'initialIndex': safeIndex - start},
          );
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            if (context.mounted) feedProvider.markAsRead(item.id);
          });
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _FeedItemContent(item: item, isRead: isRead),
                  ),
                  if (_hasThumbnail) ...[
                    const SizedBox(width: 12),
                    _FeedItemThumbnail(item: item, isRead: isRead),
                  ],
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: _FeedItemMetadata(
                      item: item,
                      isRead: isRead,
                      isCached: isCached,
                    ),
                  ),
                  _ActionIcon(
                    onTap: () => context
                        .read<BookmarkProvider>()
                        .toggleBookmark(item),
                    icon: isBookmarked
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                    color: isBookmarked
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    size: 20,
                    semanticLabel: isBookmarked
                        ? AppLocalizations.of(context).semanticRemoveBookmark
                        : AppLocalizations.of(context).semanticBookmark,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Swipe background — smooth icon scale via AnimatedScale
// =============================================================================

class _SwipeBackground extends StatelessWidget {
  final bool isSwipingRight;
  final bool isRead;
  final bool isBookmarked;
  final bool actionTriggered;

  const _SwipeBackground({
    required this.isSwipingRight,
    required this.isRead,
    required this.isBookmarked,
    required this.actionTriggered,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: isSwipingRight
              ? colorScheme.primary.withValues(alpha: 0.1)
              : colorScheme.secondary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(18),
        ),
        alignment: isSwipingRight
            ? Alignment.centerLeft
            : Alignment.centerRight,
        padding: EdgeInsets.only(
          left: isSwipingRight ? 24.0 : 0,
          right: !isSwipingRight ? 24.0 : 0,
        ),
        child: AnimatedScale(
          scale: actionTriggered ? 1.2 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutBack,
          child: Icon(
            isSwipingRight
                ? (isRead ? Icons.mark_email_unread : Icons.mark_email_read)
                : (isBookmarked ? Icons.bookmark_remove : Icons.bookmark_add),
            color: isSwipingRight ? colorScheme.primary : colorScheme.secondary,
            size: 28,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Compact thumbnail beside the headline
// =============================================================================

class _FeedItemThumbnail extends StatelessWidget {
  final FeedItem item;
  final bool isRead;

  const _FeedItemThumbnail({required this.item, required this.isRead});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Opacity(
          opacity: isRead ? 0.5 : 1.0,
          child: CachedNetworkImage(
            imageUrl: item.imageUrl!,
            cacheManager: ThumbnailCacheManager.instance,
            width: 64,
            height: 64,
            memCacheWidth: 150,
            maxWidthDiskCache: 150,
            maxHeightDiskCache: 150,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => Container(
              width: 64,
              height: 64,
              color: colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.image_outlined,
                size: 24,
                color: colorScheme.onSurface.withValues(alpha: 0.2),
              ),
            ),
            placeholder: (_, _) => Container(
              width: 64,
              height: 64,
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Headline and compact source metadata
// =============================================================================

class _FeedItemContent extends StatelessWidget {
  final FeedItem item;
  final bool isRead;

  const _FeedItemContent({required this.item, required this.isRead});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      item.title.trim(),
      style: TextStyle(
        color: isRead
            ? colorScheme.onSurface.withValues(alpha: 0.65)
            : colorScheme.onSurface,
        fontSize: 16,
        fontWeight: isRead ? FontWeight.w400 : FontWeight.w600,
        height: 1.3,
        letterSpacing: -0.1,
      ),
      // Let the complete headline wrap, including at larger text sizes.
      softWrap: true,
    );
  }
}

class _FeedItemMetadata extends StatelessWidget {
  final FeedItem item;
  final bool isRead;
  final bool isCached;

  const _FeedItemMetadata({
    required this.item,
    required this.isRead,
    required this.isCached,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (!isRead)
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsetsDirectional.only(end: 6),
            decoration: BoxDecoration(
              color: colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: truncateLabel(item.siteName, 20),
              children: [
                if (item.category != 'Uncategorized')
                  TextSpan(text: ' · ${truncateLabel(item.category, 14)}'),
                TextSpan(text: ' · ${_formatDate(item)}'),
              ],
            ),
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 11,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (item.prefetchedFullText != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: Icon(
              Icons.download_done,
              size: 14,
              color: colorScheme.secondary,
            ),
          ),
        if (isCached)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: Semantics(
              label: AppLocalizations.of(context).semanticOfflineCached,
              child: Icon(
                Icons.offline_pin,
                size: 14,
                color: colorScheme.secondary,
              ),
            ),
          ),
      ],
    );
  }

  String _formatDate(FeedItem item) {
    if (item.pubDate == null) return item.timeAgo;
    final now = DateTime.now();
    final d = item.pubDate!;
    final diff = now.difference(d);
    if (diff.isNegative || diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${d.month}/${d.day}';
  }
}

class _ActionIcon extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final Color color;
  final double size;
  final String? semanticLabel;

  const _ActionIcon({
    required this.onTap,
    required this.icon,
    required this.color,
    required this.size,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          // 20px icon + 14px padding = 48x48 minimum touch target.
          padding: const EdgeInsets.all(14.0),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}
