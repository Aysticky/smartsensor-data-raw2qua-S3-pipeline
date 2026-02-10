"""
Unit tests for common utilities
"""

import json
from datetime import date, datetime, timedelta
from unittest.mock import MagicMock, patch

import pytest

from src.common.utils import (
    CheckpointManager,
    SecretsManager,
    daterange,
    parse_date,
    validate_config,
)


class TestDateRange:
    def test_single_day(self):
        start = date(2026, 2, 1)
        end = date(2026, 2, 1)
        dates = list(daterange(start, end))
        assert len(dates) == 1
        assert dates[0] == start

    def test_multiple_days(self):
        start = date(2026, 2, 1)
        end = date(2026, 2, 5)
        dates = list(daterange(start, end))
        assert len(dates) == 5
        assert dates[0] == start
        assert dates[-1] == end

    def test_reverse_range(self):
        start = date(2026, 2, 5)
        end = date(2026, 2, 1)
        dates = list(daterange(start, end))
        assert len(dates) == 0


class TestParseDate:
    def test_yesterday(self):
        result = parse_date('yesterday')
        expected = date.today() - timedelta(days=1)
        assert result == expected

    def test_today(self):
        result = parse_date('today')
        expected = date.today()
        assert result == expected

    def test_iso_format(self):
        result = parse_date('2026-02-15')
        assert result == date(2026, 2, 15)


class TestValidateConfig:
    def test_valid_config(self):
        config = {'key1': 'value1', 'key2': 'value2'}
        required = ['key1', 'key2']
        # Should not raise
        validate_config(config, required)

    def test_missing_keys(self):
        config = {'key1': 'value1'}
        required = ['key1', 'key2']
        with pytest.raises(ValueError, match="Missing required"):
            validate_config(config, required)


class TestCheckpointManager:
    @patch('boto3.client')
    def test_read_checkpoint_success(self, mock_boto_client):
        mock_s3 = MagicMock()
        mock_boto_client.return_value = mock_s3

        checkpoint_data = {'last_date': '2026-02-10', 'rows': 1000}
        mock_s3.get_object.return_value = {
            'Body': MagicMock(read=lambda: json.dumps(checkpoint_data).encode())
        }

        manager = CheckpointManager('test-bucket', 'checkpoints/')
        result = manager.read_checkpoint('test-key')

        assert result == checkpoint_data

    @patch('boto3.client')
    def test_read_checkpoint_not_found(self, mock_boto_client):
        mock_s3 = MagicMock()
        mock_boto_client.return_value = mock_s3
        mock_s3.exceptions.NoSuchKey = Exception
        mock_s3.get_object.side_effect = mock_s3.exceptions.NoSuchKey

        manager = CheckpointManager('test-bucket', 'checkpoints/')
        result = manager.read_checkpoint('test-key')

        assert result is None

    @patch('boto3.client')
    def test_write_checkpoint_success(self, mock_boto_client):
        mock_s3 = MagicMock()
        mock_boto_client.return_value = mock_s3

        manager = CheckpointManager('test-bucket', 'checkpoints/')
        data = {'last_date': '2026-02-10'}
        result = manager.write_checkpoint('test-key', data)

        assert result is True
        mock_s3.put_object.assert_called_once()


class TestSecretsManager:
    @patch('boto3.client')
    def test_get_secret_success(self, mock_boto_client):
        mock_sm = MagicMock()
        mock_boto_client.return_value = mock_sm

        secret_data = {'api_key': 'test-key-123'}
        mock_sm.get_secret_value.return_value = {
            'SecretString': json.dumps(secret_data)
        }

        manager = SecretsManager()
        result = manager.get_secret('test-secret')

        assert result == secret_data

    @patch('boto3.client')
    def test_get_secret_cached(self, mock_boto_client):
        mock_sm = MagicMock()
        mock_boto_client.return_value = mock_sm

        secret_data = {'api_key': 'test-key-123'}
        mock_sm.get_secret_value.return_value = {
            'SecretString': json.dumps(secret_data)
        }

        manager = SecretsManager()

        # First call
        result1 = manager.get_secret('test-secret')
        # Second call (should use cache)
        result2 = manager.get_secret('test-secret')

        assert result1 == result2
        # Should only call API once
        assert mock_sm.get_secret_value.call_count == 1
