import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/colors.dart';
import '../../view_model/infra_view_model.dart';
import 'compose_builder_logic.dart';

class BuilderTab extends StatefulWidget {
  const BuilderTab({super.key});

  @override
  State<BuilderTab> createState() => _BuilderTabState();
}

class _BuilderTabState extends State<BuilderTab> {
  late ComposeStackDraft draft;

  @override
  void initState() {
    super.initState();
    draft = ComposeStackDraft();
  }

  void _addService() {
    setState(() {
      draft.services.add(ComposeServiceDraft(serviceName: 'new_service'));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Compose Builder',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            ElevatedButton.icon(
              onPressed: _addService,
              icon: const Icon(Icons.add),
              label: const Text('Add Service'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.builder(
            itemCount: draft.services.length,
            itemBuilder: (context, index) {
              final service = draft.services[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        initialValue: service.serviceName,
                        decoration: const InputDecoration(labelText: 'Service Name'),
                        onChanged: (val) {
                          service.serviceName = val;
                        },
                      ),
                      TextFormField(
                        initialValue: service.image,
                        decoration: const InputDecoration(labelText: 'Image'),
                        onChanged: (val) {
                          service.image = val;
                        },
                      ),
                      TextFormField(
                        initialValue: service.ports.join(', '),
                        decoration: const InputDecoration(labelText: 'Ports (comma separated)'),
                        onChanged: (val) {
                          service.ports = val.split(',').map((e) => e.trim()).toList();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
