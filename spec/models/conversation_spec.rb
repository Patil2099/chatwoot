# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join 'spec/models/concerns/assignment_handler_spec.rb'
require Rails.root.join 'spec/models/concerns/round_robin_handler_spec.rb'

RSpec.describe Conversation, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:inbox) }
  end

  describe 'concerns' do
    it_behaves_like 'assignment_handler'
    it_behaves_like 'round_robin_handler'
  end

  describe '.before_create' do
    let(:conversation) { build(:conversation, display_id: nil) }

    before do
      conversation.save
      conversation.reload
    end

    it 'runs before_create callbacks' do
      expect(conversation.display_id).to eq(1)
    end

    it 'creates a UUID for every conversation automatically' do
      uuid_pattern = /[0-9a-f]{8}\b-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-\b[0-9a-f]{12}$/i
      expect(conversation.uuid).to match(uuid_pattern)
    end
  end

  describe '.after_create' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, email: 'agent1@example.com', account: account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) do
      create(
        :conversation,
        account: account,
        contact: create(:contact, account: account),
        inbox: inbox,
        assignee: nil
      )
    end

    before do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'runs after_create callbacks' do
      # send_events
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(described_class::CONVERSATION_CREATED, kind_of(Time), conversation: conversation)
    end

    it 'queues AutoResolveConversationsJob post creation if auto resolve duration present' do
      account.update(auto_resolve_duration: 30)
      expect do
        create(
          :conversation,
          account: account,
          contact: create(:contact, account: account),
          inbox: inbox,
          assignee: nil
        )
      end.to have_enqueued_job(AutoResolveConversationsJob)
    end
  end

  describe '.after_update' do
    let(:account) { create(:account) }
    let(:conversation) do
      create(:conversation, status: 'open', account: account, assignee: old_assignee)
    end
    let(:old_assignee) do
      create(:user, email: 'agent1@example.com', account: account, role: :agent)
    end
    let(:new_assignee) do
      create(:user, email: 'agent2@example.com', account: account, role: :agent)
    end
    let(:assignment_mailer) { double(deliver: true) }
    let(:label) { create(:label, account: account) }

    before do
      conversation
      new_assignee

      allow(Rails.configuration.dispatcher).to receive(:dispatch)
      Current.user = old_assignee

      conversation.update(
        status: :resolved,
        contact_last_seen_at: Time.now,
        assignee: new_assignee,
        label_list: [label.title]
      )
    end

    it 'runs after_update callbacks' do
      # notify_status_change
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(described_class::CONVERSATION_RESOLVED, kind_of(Time), conversation: conversation)
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(described_class::CONVERSATION_READ, kind_of(Time), conversation: conversation)
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(described_class::ASSIGNEE_CHANGED, kind_of(Time), conversation: conversation)
    end

    it 'creates conversation activities' do
      # create_activity
      expect(conversation.messages.pluck(:content)).to include("Conversation was marked resolved by #{old_assignee.name}")
      expect(conversation.messages.pluck(:content)).to include("Assigned to #{new_assignee.name} by #{old_assignee.name}")
      expect(conversation.messages.pluck(:content)).to include("#{old_assignee.name} added #{label.title}")
    end

    it 'adds a message for system auto resolution if marked resolved by system' do
      account.update(auto_resolve_duration: 40)
      conversation2 = create(:conversation, status: 'open', account: account, assignee: old_assignee)
      Current.user = nil
      conversation2.update(status: :resolved)
      system_resolved_message = "Conversation was marked resolved by system due to #{account.auto_resolve_duration} days of inactivity"
      expect(conversation2.messages.pluck(:content)).to include(system_resolved_message)
    end

    it 'does not trigger AutoResolutionJob if conversation reopened and account does not have auto resolve duration' do
      expect { conversation.update(status: :open) }
        .not_to have_enqueued_job(AutoResolveConversationsJob).with(conversation.id)
    end

    it 'does trigger AutoResolutionJob if conversation reopened and account has auto resolve duration' do
      account.update(auto_resolve_duration: 40)
      expect { conversation.reload.update(status: :open) }
        .to have_enqueued_job(AutoResolveConversationsJob).with(conversation.id)
    end
  end

  describe '#update_labels' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:agent) do
      create(:user, email: 'agent@example.com', account: account, role: :agent)
    end
    let(:first_label) { create(:label, account: account) }
    let(:second_label) { create(:label, account: account) }
    let(:third_label) { create(:label, account: account) }
    let(:fourth_label) { create(:label, account: account) }

    before do
      conversation
      Current.user = agent

      first_label
      second_label
      third_label
      fourth_label
    end

    it 'adds one label to conversation' do
      labels = [first_label].map(&:title)
      expect(conversation.update_labels(labels)).to eq(true)
      expect(conversation.label_list).to match_array(labels)
      expect(conversation.messages.pluck(:content)).to include("#{agent.name} added #{labels.join(', ')}")
    end

    it 'adds and removes previously added labels' do
      labels = [first_label, fourth_label].map(&:title)
      expect(conversation.update_labels(labels)).to eq(true)
      expect(conversation.label_list).to match_array(labels)
      expect(conversation.messages.pluck(:content)).to include("#{agent.name} added #{labels.join(', ')}")

      updated_labels = [second_label, third_label].map(&:title)
      expect(conversation.update_labels(updated_labels)).to eq(true)
      expect(conversation.label_list).to match_array(updated_labels)
      expect(conversation.messages.pluck(:content)).to include("#{agent.name} added #{updated_labels.join(', ')}")
      expect(conversation.messages.pluck(:content)).to include("#{agent.name} removed #{labels.join(', ')}")
    end
  end

  describe '#toggle_status' do
    subject(:toggle_status) { conversation.toggle_status }

    let(:conversation) { create(:conversation, status: :open) }

    it 'toggles conversation status' do
      expect(toggle_status).to eq(true)
      expect(conversation.reload.status).to eq('resolved')
    end
  end

  describe '#mute!' do
    subject(:mute!) { conversation.mute! }

    let(:user) do
      create(:user, email: 'agent2@example.com', account: create(:account), role: :agent)
    end

    let(:conversation) { create(:conversation) }

    before { Current.user = user }

    it 'marks conversation as resolved' do
      mute!
      expect(conversation.reload.resolved?).to eq(true)
    end

    it 'marks conversation as muted in redis' do
      mute!
      expect(Redis::Alfred.get(conversation.send(:mute_key))).not_to eq(nil)
    end

    it 'creates mute message' do
      mute!
      expect(conversation.messages.pluck(:content)).to include("#{user.name} has muted the conversation")
    end
  end

  describe '#unmute!' do
    subject(:unmute!) { conversation.unmute! }

    let(:user) do
      create(:user, email: 'agent2@example.com', account: create(:account), role: :agent)
    end

    let(:conversation) { create(:conversation).tap(&:mute!) }

    before { Current.user = user }

    it 'does not change conversation status' do
      expect { unmute! }.not_to(change { conversation.reload.status })
    end

    it 'marks conversation as muted in redis' do
      expect { unmute! }
        .to change { Redis::Alfred.get(conversation.send(:mute_key)) }
        .to nil
    end

    it 'creates unmute message' do
      unmute!
      expect(conversation.messages.pluck(:content)).to include("#{user.name} has unmuted the conversation")
    end
  end

  describe '#muted?' do
    subject(:muted?) { conversation.muted? }

    let(:conversation) { create(:conversation) }

    it 'return true if conversation is muted' do
      conversation.mute!
      expect(muted?).to eq(true)
    end

    it 'returns false if conversation is not muted' do
      expect(muted?).to eq(false)
    end
  end

  describe 'unread_messages' do
    subject(:unread_messages) { conversation.unread_messages }

    let(:conversation) { create(:conversation, agent_last_seen_at: 1.hour.ago) }
    let(:message_params) do
      {
        conversation: conversation,
        account: conversation.account,
        inbox: conversation.inbox,
        sender: conversation.assignee
      }
    end
    let!(:message) do
      create(:message, created_at: 1.minute.ago, **message_params)
    end

    before do
      create(:message, created_at: 1.month.ago, **message_params)
    end

    it 'returns unread messages' do
      expect(unread_messages).to include(message)
    end
  end

  describe 'unread_incoming_messages' do
    subject(:unread_incoming_messages) { conversation.unread_incoming_messages }

    let(:conversation) { create(:conversation, agent_last_seen_at: 1.hour.ago) }
    let(:message_params) do
      {
        conversation: conversation,
        account: conversation.account,
        inbox: conversation.inbox,
        sender: conversation.assignee,
        created_at: 1.minute.ago
      }
    end
    let!(:message) do
      create(:message, message_type: :incoming, **message_params)
    end

    before do
      create(:message, message_type: :outgoing, **message_params)
    end

    it 'returns unread incoming messages' do
      expect(unread_incoming_messages).to contain_exactly(message)
    end
  end

  describe '#push_event_data' do
    subject(:push_event_data) { conversation.push_event_data }

    let(:conversation) { create(:conversation) }
    let(:expected_data) do
      {
        additional_attributes: {},
        meta: {
          sender: conversation.contact.push_event_data,
          assignee: conversation.assignee
        },
        id: conversation.display_id,
        messages: [],
        inbox_id: conversation.inbox_id,
        status: conversation.status,
        contact_inbox: conversation.contact_inbox,
        timestamp: conversation.last_activity_at.to_i,
        can_reply: true,
        channel: 'Channel::WebWidget',
        contact_last_seen_at: conversation.contact_last_seen_at.to_i,
        agent_last_seen_at: conversation.agent_last_seen_at.to_i,
        unread_count: 0
      }
    end

    it 'returns push event payload' do
      expect(push_event_data).to eq(expected_data)
    end
  end

  describe '#botinbox: when conversation created inside inbox with agent bot' do
    let!(:bot_inbox) { create(:agent_bot_inbox) }
    let(:conversation) { create(:conversation, inbox: bot_inbox.inbox) }

    it 'returns conversation status as pending' do
      expect(conversation.status).to eq('pending')
    end
  end

  describe '#botintegration: when conversation created in inbox with dialogflow integration' do
    let(:hook) { create(:integrations_hook, :dialogflow) }
    let(:conversation) { create(:conversation, inbox: hook.inbox) }

    it 'returns conversation status as pending' do
      expect(conversation.status).to eq('pending')
    end
  end

  describe '#can_reply?' do
    describe 'on channels without 24 hour restriction' do
      let(:conversation) { create(:conversation) }

      it 'returns true' do
        expect(conversation.can_reply?).to eq true
      end
    end

    describe 'on channels with 24 hour restriction' do
      let!(:facebook_channel) { create(:channel_facebook_page) }
      let!(:facebook_inbox) { create(:inbox, channel: facebook_channel, account: facebook_channel.account) }
      let!(:conversation) { create(:conversation, inbox: facebook_inbox, account: facebook_channel.account) }

      it 'returns false if there are no incoming messages' do
        expect(conversation.can_reply?).to eq false
      end

      it 'return false if last incoming message is outside of 24 hour window' do
        create(
          :message,
          account: conversation.account,
          inbox: facebook_inbox,
          conversation: conversation,
          created_at: Time.now - 25.hours
        )
        expect(conversation.can_reply?).to eq false
      end

      it 'return true if last incoming message is inside 24 hour window' do
        create(
          :message,
          account: conversation.account,
          inbox: facebook_inbox,
          conversation: conversation
        )
        expect(conversation.can_reply?).to eq true
      end
    end
  end

  describe '#delete conversation' do
    let!(:conversation) { create(:conversation) }

    let!(:notification) { create(:notification, notification_type: 'conversation_creation', primary_actor: conversation) }

    it 'delete associated notifications if conversation is deleted' do
      conversation.destroy
      expect { notification.reload }.to raise_error ActiveRecord::RecordNotFound
    end
  end
end
