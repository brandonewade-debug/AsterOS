import SwiftUI
import WebKit

struct EditorOption: Decodable, Hashable { let value: String; let label: String; let disabled: Bool }
struct EditorField: Decodable, Identifiable {
    let id: String; let label: String; let group: String; let kind: String
    let value: String; let checked: Bool; let values: [String]; let options: [EditorOption]
    let required: Bool; let disabled: Bool
}
struct EditorAction: Decodable, Identifiable { let id: String; let label: String; let destructive: Bool }
struct EditorForm: Decodable {
    let fields: [EditorField]; let actions: [EditorAction]; let dialog: Bool; let title: String
}
enum NativeEditorBridge {
    // Read only the Docker configuration form. Login fields and hidden CSRF/session data
    // never cross into the native UI. Configuration values stay in memory, never cache/logs.
    static let helpers = #"""
    const form = document.querySelector('#canvas form[method="POST"], #canvas form[method="post"]');
    if (!form || !form.querySelector('[name="contName"]')) return null;
    const visible = (el, includeSelf = true) => {
        for(let node = includeSelf ? el : el.parentElement; node; node = node.parentElement) {
            const style = getComputedStyle(node);
            if(style.display === 'none' || style.visibility === 'hidden') return false;
        }
        return true;
    };
    const popup = document.querySelector('#dialogAddConfig');
    const dialog = popup && visible(popup) ? popup.closest('.ui-dialog') || popup : null;
    const root = dialog || form;
    const clean = text => (text || '').replace(/\s+/g, ' ').trim().slice(0, 200);
    const identify = el => {
        if (!el.dataset.asterEditorID) el.dataset.asterEditorID = 'field-' + (window.asterEditorSequence = (window.asterEditorSequence || 0) + 1);
        return el.dataset.asterEditorID;
    };
    const label = el => {
        const block = el.closest('[id^="ConfigNum"]');
        const name = block?.querySelector('[name="confName[]"]')?.value;
        const label = el.labels?.[0]?.textContent;
        const dd = el.closest('dd');
        const preceding = dd?.previousElementSibling;
        const cpu = el.id?.startsWith('box') ? document.getElementById(el.id.replace('box', 'cpu'))?.textContent : null;
        return clean(name || label || (preceding?.tagName === 'DT' ? preceding.textContent : '') || (cpu ? 'CPU ' + cpu : '') || el.getAttribute('aria-label') || el.name?.replace(/^cont/, '').replace(/([a-z])([A-Z])/g, '$1 $2') || el.id || 'Setting').replace(/:$/, '');
    };
    const allowedAction = el => {
        if (dialog) return el.matches('.ui-dialog-buttonpane button');
        const code = (el.getAttribute('onclick') || el.getAttribute('href') || '').replace(/^javascript:/, '').trim();
        return /^(editConfigPopup|removeConfig|toggleReadmore|addConfigPopup)\(/.test(code);
    };
    """#
    static let snapshot = helpers + #"""
    const fields = Array.from(root.querySelectorAll('input,select,textarea')).filter(el =>
        !['hidden','submit','button','reset','file','image'].includes(el.type) && visible(el, false)
    ).map(el => ({id: identify(el), label: label(el), group: el.closest('[id^="ConfigNum"]') ? 'Paths, ports & variables' : 'Configuration',
        kind: el.tagName === 'SELECT' ? (el.multiple ? 'multiple' : 'select') : (el.tagName === 'TEXTAREA' ? 'textArea' : el.type),
        value: el.value || '', checked: !!el.checked, values: el.selectedOptions ? Array.from(el.selectedOptions).map(o => o.value) : [],
        options: el.options ? Array.from(el.options).map(o => ({value:o.value,label:clean(o.textContent),disabled:o.disabled})) : [],
        required: !!el.required, disabled: !!el.disabled || !!el.readOnly
    }));
    const actions = Array.from(root.querySelectorAll('a,button,input[type="button"]')).filter(el => allowedAction(el) && visible(el)).map(el => {
        const block = el.closest('[id^="ConfigNum"]');
        const name = block?.querySelector('[name="confName[]"]')?.value;
        return {id:identify(el), label:clean(el.textContent || el.value) + (name ? ' · ' + name : ''), destructive:(el.getAttribute('onclick') || '').trim().startsWith('removeConfig(')};
    });
    return JSON.stringify({fields,actions,dialog:!!dialog,title:dialog ? clean(dialog.querySelector('.ui-dialog-title')?.textContent || 'Configuration item') : 'Container configuration'});
    """#
    static let update = helpers + #"""
    const el = Array.from(root.querySelectorAll('input,select,textarea')).find(el => el.dataset.asterEditorID === fieldID);
    if (!el || el.disabled || el.readOnly || ['hidden','submit','button','reset','file','image'].includes(el.type)) return 'This field is no longer editable.';
    if (el.type === 'checkbox' || el.type === 'radio') { if (el.checked !== checked) el.click(); }
    else if(el.tagName === 'SELECT' && el.multiple) {
        for(const option of el.options) if(!option.disabled) option.selected = values.includes(option.value);
        el.dispatchEvent(new Event('change', {bubbles:true}));
    } else {
        if(el.tagName === 'SELECT' && !Array.from(el.options).some(o => o.value === value && !o.disabled)) return 'Choose a valid option.';
        el.value = value; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));
    }
    return '';
    """#
    static let action = helpers + #"""
    const el = Array.from(root.querySelectorAll('a,button,input[type="button"]')).find(el => el.dataset.asterEditorID === actionID);
    if(!el || !allowedAction(el) || !visible(el) || el.disabled) return 'This action is no longer available.';
    el.click(); return '';
    """#
    static let apply = helpers + #"""
    if(dialog) return 'Finish editing the configuration item first.';
    const invalid = Array.from(form.elements).find(el => el.willValidate && !el.validity.valid);
    if(invalid) return label(invalid) + ': ' + invalid.validationMessage;
    const submit = form.querySelector('input[type="submit"]');
    if(!submit || submit.disabled) return 'Apply is not available for this template.';
    form.requestSubmit(submit); return '';
    """#
}
struct NativeContainerForm: View {
    @ObservedObject var model: CatalogBrowserModel
    @State private var editingField: EditorField?
    @State private var pendingAction: EditorAction?
    @State private var confirmApply = false
    var body: some View {
        GlassForm {
            if model.applyingConfiguration {
                Section {
                    ProgressView("Applying configuration…")
                    Text("Unraid may pull an image and recreate the container. Keep this screen open.").foregroundStyle(.secondary)
                }
            } else if let result = model.configurationResult {
                Section { Label(result, systemImage: "info.circle"); Text("Close the editor to refresh your apps. If the connection was interrupted, check the container before retrying.").font(.caption).foregroundStyle(.secondary) }
            } else if let form = model.nativeEditor {
                Section {
                    Text(form.title).font(.title2.bold())
                    if let advanced = model.editorAdvanced, !form.dialog {
                        Toggle("Advanced mode", isOn: Binding(get: { model.editorAdvanced ?? advanced }, set: { value in Task { await model.setEditorAdvanced(value) } }))
                    }
                }
                ForEach(["Configuration", "Paths, ports & variables"], id: \.self) { group in
                    let fields = form.fields.filter { $0.group == group }
                    if !fields.isEmpty {
                        Section(group) {
                            ForEach(fields) { field in
                                if field.kind == "checkbox" || field.kind == "radio" {
                                    Toggle(field.label, isOn: Binding(get: { field.checked }, set: { value in Task { await model.updateEditorField(field, checked: value) } }))
                                        .disabled(field.disabled || model.editingConfiguration)
                                } else {
                                    Button { editingField = field } label: {
                                        HStack {
                                            Text(field.label + (field.required ? " *" : "")).foregroundStyle(.primary)
                                            Spacer()
                                            Text(field.kind == "password" ? (field.value.isEmpty ? "Not set" : "••••••••") : (field.kind == "multiple" ? field.options.filter { field.values.contains($0.value) }.map(\.label).joined(separator: ", ") : field.options.first { $0.value == field.value }?.label ?? field.value))
                                                .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.disabled(field.disabled || model.editingConfiguration)
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(form.actions) { action in
                        Button(action.label, role: action.destructive ? .destructive : nil) {
                            if action.destructive { pendingAction = action }
                            else { Task { await model.performEditorAction(action) } }
                        }.disabled(model.editingConfiguration)
                    }
                }
                if !form.dialog {
                    Section {
                        Button(model.editingContainer == nil ? "Install container" : "Apply changes") { confirmApply = true }
                            .buttonStyle(.borderedProminent).disabled(model.editingConfiguration)
                        Text("Changes are kept in this editor until you apply them. Applying may recreate or restart the container.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section { ProgressView("Loading container settings…"); Text("Preparing your template").foregroundStyle(.secondary) }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .alert(model.dialog?.host ?? "Server", isPresented: Binding(get: { model.dialog != nil }, set: { if !$0 { model.answerDialog(false) } })) {
            if model.dialog?.confirm == true { Button("Continue") { model.answerDialog(true) }; Button("Cancel", role: .cancel) { model.answerDialog(false) } }
            else { Button("OK") { model.answerDialog(true) } }
        } message: { Text(model.dialog?.message ?? "") }
        .sheet(item: $editingField) { EditorFieldSheet(field: $0, model: model) }
        .confirmationDialog("Apply this configuration?", isPresented: $confirmApply, titleVisibility: .visible) {
            Button(model.editingContainer == nil ? "Install container" : "Apply changes") { Task { await model.applyEditorConfiguration() } }
        } message: { Text("Unraid will validate the template and may recreate or restart the container. Its mounted data stays on the server.") }
        .confirmationDialog("Remove this configuration item?", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let action = pendingAction { Button("Remove item", role: .destructive) { pendingAction = nil; Task { await model.performEditorAction(action) } } }
        }
    }
}
struct EditorFieldSheet: View {
    let field: EditorField
    @ObservedObject var model: CatalogBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var values: Set<String>
    @State private var saving = false
    init(field: EditorField, model: CatalogBrowserModel) {
        self.field = field; self.model = model
        _value = State(initialValue: field.value); _values = State(initialValue: Set(field.values))
    }
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    if field.kind == "select" {
                        Picker(field.label, selection: $value) { ForEach(Array(field.options.enumerated()), id: \.offset) { _, option in Text(option.label).tag(option.value).disabled(option.disabled) } }
                    } else if field.kind == "multiple" {
                        ForEach(Array(field.options.enumerated()), id: \.offset) { _, option in
                            Toggle(option.label, isOn: Binding(get: { values.contains(option.value) }, set: { if $0 { values.insert(option.value) } else { values.remove(option.value) } })).disabled(option.disabled)
                        }
                    } else if field.kind == "password" { SecureField(field.label, text: $value).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else if field.kind == "textArea" { TextEditor(text: $value).frame(minHeight: 180).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { TextField(field.label, text: $value, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                }
            }.navigationTitle(field.label).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { saving = true; Task { let updated = await model.updateEditorField(field, value: value, values: Array(values)); saving = false; if updated { dismiss() } } }.disabled(saving) }
                }.interactiveDismissDisabled(saving)
        }
    }
}
