import React, { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import client from '../api/client';
import { useToast } from '../components/Toast';

const INITIAL = {
  first_name: '',
  last_name: '',
  email: '',
  phone_main: '',
  ext: '',
  sip_username: '',
  password: '',
  status: 'active',
  role: 'user',
};

export default function UserForm() {
  const { id } = useParams();
  const navigate = useNavigate();
  const toast = useToast();
  const isEdit = Boolean(id);

  const [form, setForm] = useState(INITIAL);
  const [errors, setErrors] = useState({});
  const [loading, setLoading] = useState(false);
  const [fetching, setFetching] = useState(isEdit);

  useEffect(() => {
    if (!isEdit) return;
    const load = async () => {
      try {
        const res = await client.get(`/admin/users/${id}`);
        const u = res.data;
        setForm({
          first_name: u.first_name || '',
          last_name: u.last_name || '',
          email: u.email || '',
          phone_main: u.phone_main || '',
          ext: u.ext || '',
          sip_username: u.sip_username || '',
          password: '',
          status: u.status || 'active',
          role: u.role || 'user',
        });
      } catch {
        toast.error('Failed to load user data');
        navigate('/users');
      } finally {
        setFetching(false);
      }
    };
    load();
  }, [id, isEdit]);

  const validate = () => {
    const errs = {};
    if (!form.email.trim()) errs.email = 'Email is required';
    if (!isEdit && !form.password.trim()) errs.password = 'Password is required for new users';
    if (form.password && form.password.length < 6) errs.password = 'Password must be at least 6 characters';
    return errs;
  };

  const handleChange = (e) => {
    const { name, value } = e.target;
    setForm(prev => ({ ...prev, [name]: value }));
    if (errors[name]) setErrors(prev => ({ ...prev, [name]: '' }));
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    const errs = validate();
    if (Object.keys(errs).length) {
      setErrors(errs);
      return;
    }
    setLoading(true);
    try {
      const payload = { ...form };
      if (isEdit && !payload.password) delete payload.password;
      if (isEdit) {
        await client.put(`/admin/users/${id}`, payload);
        toast.success('User updated successfully');
      } else {
        await client.post('/admin/users', payload);
        toast.success('User created successfully');
      }
      navigate('/users');
    } catch (err) {
      const msg = err.response?.data?.message || 'Failed to save user';
      toast.error(msg);
    } finally {
      setLoading(false);
    }
  };

  if (fetching) {
    return (
      <div className="loading-state">
        <div className="spinner" />
        <span>Loading user data…</span>
      </div>
    );
  }

  return (
    <div style={{ maxWidth: 720 }}>
      <div className="page-header">
        <div className="page-header-left">
          <h2>{isEdit ? 'Edit User' : 'Create User'}</h2>
          <p>{isEdit ? 'Update user information' : 'Add a new user to the system'}</p>
        </div>
        <button className="btn btn-secondary" onClick={() => navigate('/users')}>
          ← Back to Users
        </button>
      </div>

      <div className="card">
        <div className="card-body">
          <form onSubmit={handleSubmit}>
            <div className="form-section">
              <div className="form-section-title">Personal Information</div>
              <div className="form-row">
                <div className="form-group">
                  <label className="form-label" htmlFor="first_name">First Name</label>
                  <input
                    id="first_name"
                    name="first_name"
                    type="text"
                    className="form-input"
                    placeholder="Alice"
                    value={form.first_name}
                    onChange={handleChange}
                  />
                </div>
                <div className="form-group">
                  <label className="form-label" htmlFor="last_name">Last Name</label>
                  <input
                    id="last_name"
                    name="last_name"
                    type="text"
                    className="form-input"
                    placeholder="Smith"
                    value={form.last_name}
                    onChange={handleChange}
                  />
                </div>
              </div>

              <div className="form-group">
                <label className="form-label" htmlFor="email">
                  Email Address <span className="required">*</span>
                </label>
                <input
                  id="email"
                  name="email"
                  type="email"
                  className={`form-input ${errors.email ? 'error' : ''}`}
                  placeholder="alice@example.com"
                  value={form.email}
                  onChange={handleChange}
                />
                {errors.email && <p className="form-error">{errors.email}</p>}
              </div>
            </div>

            <div className="form-section">
              <div className="form-section-title">Phone & SIP</div>
              <div className="form-row-3">
                <div className="form-group">
                  <label className="form-label" htmlFor="phone_main">Phone Number</label>
                  <input
                    id="phone_main"
                    name="phone_main"
                    type="text"
                    className="form-input"
                    placeholder="+15551111111"
                    value={form.phone_main}
                    onChange={handleChange}
                  />
                </div>
                <div className="form-group">
                  <label className="form-label" htmlFor="ext">Extension</label>
                  <input
                    id="ext"
                    name="ext"
                    type="text"
                    className="form-input"
                    placeholder="101"
                    value={form.ext}
                    onChange={handleChange}
                  />
                </div>
                <div className="form-group">
                  <label className="form-label" htmlFor="sip_username">SIP Username</label>
                  <input
                    id="sip_username"
                    name="sip_username"
                    type="text"
                    className="form-input"
                    placeholder="alice"
                    value={form.sip_username}
                    onChange={handleChange}
                  />
                </div>
              </div>
            </div>

            <div className="form-section">
              <div className="form-section-title">Account Settings</div>
              <div className="form-row">
                <div className="form-group">
                  <label className="form-label" htmlFor="status">Status</label>
                  <select
                    id="status"
                    name="status"
                    className="form-select"
                    value={form.status}
                    onChange={handleChange}
                  >
                    <option value="active">Active</option>
                    <option value="inactive">Inactive</option>
                  </select>
                </div>
                <div className="form-group">
                  <label className="form-label" htmlFor="role">Role</label>
                  <select
                    id="role"
                    name="role"
                    className="form-select"
                    value={form.role}
                    onChange={handleChange}
                  >
                    <option value="user">User</option>
                    <option value="admin">Admin</option>
                  </select>
                </div>
              </div>

              <div className="form-group">
                <label className="form-label" htmlFor="password">
                  Password {!isEdit && <span className="required">*</span>}
                </label>
                <input
                  id="password"
                  name="password"
                  type="password"
                  className={`form-input ${errors.password ? 'error' : ''}`}
                  placeholder={isEdit ? 'Leave blank to keep current password' : 'Enter password'}
                  value={form.password}
                  onChange={handleChange}
                  autoComplete="new-password"
                />
                {errors.password && <p className="form-error">{errors.password}</p>}
                {isEdit && (
                  <p className="form-hint">Leave blank to keep the existing password unchanged.</p>
                )}
              </div>
            </div>

            <div className="form-actions">
              <button type="submit" className="btn btn-primary" disabled={loading}>
                {loading ? (
                  <><span className="spinner spinner-sm" /> Saving…</>
                ) : (
                  isEdit ? '💾 Save Changes' : '+ Create User'
                )}
              </button>
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => navigate('/users')}
                disabled={loading}
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}
