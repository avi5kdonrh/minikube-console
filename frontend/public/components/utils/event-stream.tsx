import type { FC, ComponentType } from 'react';
import { Component } from 'react';
import { css } from '@patternfly/react-styles';
import type { EventKind } from '../../module/k8s';

// Keep track of seen events so we only animate new ones.
const seen = new Set();

class SysEvent extends Component<SysEventProps> {
  shouldComponentUpdate(nextProps: SysEventProps) {
    // Timestamps can be modified because events can be combined.
    return this.props.event.lastTimestamp !== nextProps.event.lastTimestamp;
  }

  componentWillUnmount() {
    // TODO (kans): this is not correct, but don't memory leak :-/
    seen.delete(this.props.event.metadata.uid);
  }

  render() {
    const { EventComponent, index, event, className } = this.props;

    let shouldAnimate: boolean;
    const key = event.metadata.uid;
    // Only animate events if they're at the start of the list (first 6) and we haven't seen them before.
    if (!seen.has(key) && index < 6) {
      seen.add(key);
      shouldAnimate = true;
    }

    return (
      <div
        className={css(
          { 'co-sysevent-slide-in': shouldAnimate },
          'co-sysevent--transition',
          className,
        )}
      >
        <EventComponent event={event} />
      </div>
    );
  }
}

// Render the event stream as a plain, non-virtualized list.
//
// The stream is bounded (see `maxMessages` in events.tsx), so windowing isn't
// needed. The previous react-virtualized implementation relied on a
// `WindowScroller` locating a scrollable ancestor that reported a non-zero
// height; inside the resource detail-page Events tab that resolved to height 0
// (no usable scroll container), so the list mounted zero rows and the tab
// showed "Showing N events" above an empty list even though the events had
// loaded.
export const EventStreamList: FC<EventStreamListProps> = ({
  events,
  className,
  EventComponent,
}) => (
  <>
    {events.map((event, index) => (
      <SysEvent
        className={className}
        event={event}
        EventComponent={EventComponent}
        index={index}
        key={event.metadata.uid}
      />
    ))}
  </>
);

type EventStreamListProps = {
  events: EventKind[];
  EventComponent: ComponentType<EventComponentProps>;
  className?: string;
};

export type EventComponentProps = {
  event: EventKind;
};

type SysEventProps = {
  EventComponent: ComponentType<EventComponentProps>;
  event: EventKind;
  index: number;
  className?: string;
};
